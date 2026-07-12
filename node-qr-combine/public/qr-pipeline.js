(() => {
  "use strict";

  const ROLE_ORDER = ["TL", "TR", "BL", "BR"];
  const ROLE_COLORS = {
    TL: "#ff6b6b",
    TR: "#4dabf7",
    BL: "#51cf66",
    BR: "#fcc419",
  };

  const DEFAULTS = {
    maxDetectSide: 720,
    // フラグメント検出用のセルサイズ（大きめにして QR モジュール内の穴を減らす）
    cellSize: 12,
    // セルを「フラグメント内」と判定する閾値（白ピクセル率 ≥ この値）
    lightCellRatio: 0.10,
    // Connected component の最小セル数
    minCellCount: 6,
    // 検出ボックスの最小ピクセルサイズ
    minBoxSize: 24,
    // 検出ボックスをソース座標に変換する際の拡張率
    boxExpandRatio: 0.08,
    // k-means の反復回数
    clusterIterations: 10,
    // morphological closing のカーネル半径（セル単位）
    closeRadius: 3,
  };

  let lastDebug = null;

  function process(imageData, options) {
    const result = processWithDebug(imageData, options);
    lastDebug = result.debug;
    return result.text;
  }

  function processWithDebug(imageData, options) {
    const config = Object.assign({}, DEFAULTS, options || {});
    const emptyDebug = { threshold: 0, binarized: null, regions: null, combined: null, roles: null };

    if (!isValidImageData(imageData)) {
      return { text: null, debug: emptyDebug };
    }

    const sourceCanvas = imageDataToCanvas(imageData);
    const sourceWidth = imageData.width;
    const sourceHeight = imageData.height;

    // 検出用にリサイズ
    const detectScale = Math.min(1, config.maxDetectSide / Math.max(sourceWidth, sourceHeight));
    const detectWidth = clamp(Math.round(sourceWidth * detectScale), 80, 4096);
    const detectHeight = clamp(Math.round(sourceHeight * detectScale), 80, 4096);

    const detectCanvas = document.createElement("canvas");
    detectCanvas.width = detectWidth;
    detectCanvas.height = detectHeight;
    const detectCtx = detectCanvas.getContext("2d", { willReadFrequently: true });
    detectCtx.imageSmoothingEnabled = false;
    detectCtx.drawImage(sourceCanvas, 0, 0, detectWidth, detectHeight);

    const detectImage = detectCtx.getImageData(0, 0, detectWidth, detectHeight);
    const gray = toGrayscale(detectImage.data);
    const threshold = otsuThreshold(gray);
    const binary = toBinary(gray, threshold);
    const binarizedImage = binaryToImageData(binary, detectWidth, detectHeight);

    // Step 1: 背景が暗いか明るいか判定
    const bgIsDark = detectBackgroundType(binary, detectWidth, detectHeight);

    // Step 2: フラグメント領域を含むセルを検出
    const cellInfo = buildCellGrid(binary, detectWidth, detectHeight, config.cellSize, config.lightCellRatio, bgIsDark);

    if (cellInfo.activeCells.length === 0) {
      return { text: null, debug: { threshold, binarized: binarizedImage, regions: binarizedImage, combined: null, roles: null } };
    }

    // Step 3: morphological closing でセルグリッドの穴を埋める
    const closedGrid = morphClose(cellInfo.grid, cellInfo.cols, cellInfo.rows, config.closeRadius);

    // Step 4: Connected components でフラグメント候補を検出
    const componentBoxes = findComponentBoxes(closedGrid, cellInfo.rows, cellInfo.cols, cellInfo.cellSize, config.minCellCount, config.minBoxSize, detectWidth, detectHeight);

    // Step 5: コンテンツ境界を計算
    const contentBounds = computeBoundsFromCells(cellInfo.activeCells, detectWidth, detectHeight);
    if (!contentBounds) {
      return { text: null, debug: { threshold, binarized: binarizedImage, regions: binarizedImage, combined: null, roles: null } };
    }

    // Step 6: 4 つのフラグメント領域を確定
    let regionBoxes;
    if (componentBoxes.length >= 4) {
      // 最大4つを選択
      regionBoxes = componentBoxes.sort((a, b) => boxArea(b) - boxArea(a)).slice(0, 4);
    } else if (componentBoxes.length >= 2) {
      // 一部しか検出できなかった場合、k-means で補完
      regionBoxes = kMeansClusterCells(cellInfo.activeCells, contentBounds, 4, config.clusterIterations);
      if (regionBoxes.length < 4) {
        regionBoxes = fallbackQuadrants(contentBounds);
      }
    } else {
      // フォールバック: k-means
      regionBoxes = kMeansClusterCells(cellInfo.activeCells, contentBounds, 4, config.clusterIterations);
      if (regionBoxes.length < 4) {
        regionBoxes = fallbackQuadrants(contentBounds);
      }
    }

    // 4 つに足りない場合はフォールバックで埋める
    if (regionBoxes.length < 4) {
      const fb = fallbackQuadrants(contentBounds);
      while (regionBoxes.length < 4) {
        regionBoxes.push(fb[regionBoxes.length]);
      }
    }

    // Step 7: TL/TR/BL/BR を割り当て
    const roles = assignRolesByCorners(regionBoxes.slice(0, 4));
    const regionsImage = drawRegionsDebugImage(binarizedImage, componentBoxes, roles);

    // Step 8: ソース座標に変換してクロップ → 正規化 → 結合 → デコード
    const sourceScaleX = sourceWidth / detectWidth;
    const sourceScaleY = sourceHeight / detectHeight;

    const sourceBoxes = {};
    for (const role of ROLE_ORDER) {
      const box = roles[role];
      sourceBoxes[role] = toSourceBox(box, sourceScaleX, sourceScaleY, sourceWidth, sourceHeight, config.boxExpandRatio);
    }

    const targetSide = computeTargetSide(sourceBoxes);
    const combinedCanvas = document.createElement("canvas");
    combinedCanvas.width = targetSide * 2;
    combinedCanvas.height = targetSide * 2;
    const combinedCtx = combinedCanvas.getContext("2d", { willReadFrequently: true });
    combinedCtx.imageSmoothingEnabled = false;
    combinedCtx.fillStyle = "#ffffff";
    combinedCtx.fillRect(0, 0, combinedCanvas.width, combinedCanvas.height);

    drawRoleCrop(combinedCtx, sourceCanvas, sourceBoxes.TL, 0, 0, targetSide, targetSide);
    drawRoleCrop(combinedCtx, sourceCanvas, sourceBoxes.TR, targetSide, 0, targetSide, targetSide);
    drawRoleCrop(combinedCtx, sourceCanvas, sourceBoxes.BL, 0, targetSide, targetSide, targetSide);
    drawRoleCrop(combinedCtx, sourceCanvas, sourceBoxes.BR, targetSide, targetSide, targetSide, targetSide);

    const combinedImage = combinedCtx.getImageData(0, 0, combinedCanvas.width, combinedCanvas.height);

    // 結合画像を二値化してからデコード（より安定）
    const combinedGray = toGrayscale(combinedImage.data);
    const combinedThreshold = otsuThreshold(combinedGray);
    const combinedBinary = toBinary(combinedGray, combinedThreshold);
    const combinedBinaryImage = binaryToImageData(combinedBinary, combinedCanvas.width, combinedCanvas.height);

    let text = decodeWithJsQR(combinedBinaryImage);
    if (!text) {
      text = decodeWithJsQR(combinedImage);
    }

    const debug = {
      threshold,
      bgIsDark,
      binarized: binarizedImage,
      regions: regionsImage,
      combined: combinedBinaryImage,
      roles,
    };

    return { text, debug };
  }

  function getLastDebug() {
    return lastDebug;
  }

  // ---- ユーティリティ ----

  function isValidImageData(imageData) {
    return (
      imageData &&
      imageData.width > 0 &&
      imageData.height > 0 &&
      imageData.data &&
      imageData.data.length === imageData.width * imageData.height * 4
    );
  }

  function clamp(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function boxArea(box) {
    return Math.max(0, box.width) * Math.max(0, box.height);
  }

  function imageDataToCanvas(imageData) {
    const canvas = document.createElement("canvas");
    canvas.width = imageData.width;
    canvas.height = imageData.height;
    const ctx = canvas.getContext("2d");
    ctx.putImageData(imageData, 0, 0);
    return canvas;
  }

  // ---- グレースケール・二値化 ----

  function toGrayscale(rgba) {
    const gray = new Uint8ClampedArray(rgba.length / 4);
    let gi = 0;
    for (let i = 0; i < rgba.length; i += 4) {
      gray[gi] = (rgba[i] * 299 + rgba[i + 1] * 587 + rgba[i + 2] * 114) / 1000;
      gi += 1;
    }
    return gray;
  }

  function otsuThreshold(gray) {
    const hist = new Uint32Array(256);
    for (let i = 0; i < gray.length; i += 1) {
      hist[gray[i]] += 1;
    }
    const total = gray.length;
    let sumAll = 0;
    for (let i = 0; i < 256; i += 1) {
      sumAll += i * hist[i];
    }
    let sumBg = 0;
    let wBg = 0;
    let maxVar = -1;
    let threshold = 127;
    for (let t = 0; t < 256; t += 1) {
      wBg += hist[t];
      if (wBg === 0) continue;
      const wFg = total - wBg;
      if (wFg === 0) break;
      sumBg += t * hist[t];
      const meanBg = sumBg / wBg;
      const meanFg = (sumAll - sumBg) / wFg;
      const variance = wBg * wFg * (meanBg - meanFg) * (meanBg - meanFg);
      if (variance > maxVar) {
        maxVar = variance;
        threshold = t;
      }
    }
    return clamp(threshold, 16, 240);
  }

  function toBinary(gray, threshold) {
    const binary = new Uint8Array(gray.length);
    for (let i = 0; i < gray.length; i += 1) {
      binary[i] = gray[i] < threshold ? 1 : 0; // 1=dark, 0=light
    }
    return binary;
  }

  function binaryToImageData(binary, width, height) {
    const rgba = new Uint8ClampedArray(width * height * 4);
    for (let i = 0; i < binary.length; i += 1) {
      const v = binary[i] ? 0 : 255;
      const p = i * 4;
      rgba[p] = v;
      rgba[p + 1] = v;
      rgba[p + 2] = v;
      rgba[p + 3] = 255;
    }
    return new ImageData(rgba, width, height);
  }

  // ---- 背景判定 ----

  function detectBackgroundType(binary, width, height) {
    // 画像の4辺のピクセルをサンプリングして暗/明を判定
    let darkCount = 0;
    let total = 0;

    for (let x = 0; x < width; x += 1) {
      darkCount += binary[x]; // top row
      darkCount += binary[(height - 1) * width + x]; // bottom row
      total += 2;
    }
    for (let y = 1; y < height - 1; y += 1) {
      darkCount += binary[y * width]; // left col
      darkCount += binary[y * width + width - 1]; // right col
      total += 2;
    }

    return (darkCount / total) > 0.5; // true = dark background
  }

  // ---- 積分画像 ----

  function buildIntegral(binary, width, height) {
    const integral = new Uint32Array((width + 1) * (height + 1));
    for (let y = 0; y < height; y += 1) {
      let rowSum = 0;
      for (let x = 0; x < width; x += 1) {
        rowSum += binary[y * width + x];
        integral[(y + 1) * (width + 1) + (x + 1)] = integral[y * (width + 1) + (x + 1)] + rowSum;
      }
    }
    return integral;
  }

  function rectSum(integral, width, x0, y0, x1, y1) {
    const s = width + 1;
    return integral[y1 * s + x1] - integral[y1 * s + x0] - integral[y0 * s + x1] + integral[y0 * s + x0];
  }

  // ---- セルグリッド構築 ----

  function buildCellGrid(binary, width, height, cellSize, lightCellRatio, bgIsDark) {
    const integral = buildIntegral(binary, width, height);
    const cols = Math.ceil(width / cellSize);
    const rows = Math.ceil(height / cellSize);
    const grid = new Uint8Array(cols * rows);
    const activeCells = [];

    for (let row = 0; row < rows; row += 1) {
      for (let col = 0; col < cols; col += 1) {
        const x0 = col * cellSize;
        const y0 = row * cellSize;
        const x1 = Math.min(width, x0 + cellSize);
        const y1 = Math.min(height, y0 + cellSize);
        const area = (x1 - x0) * (y1 - y0);
        if (area <= 0) continue;

        const darkCount = rectSum(integral, width, x0, y0, x1, y1);
        const lightCount = area - darkCount;

        let isFragment;
        if (bgIsDark) {
          // 黒背景: 白ピクセルが一定以上あるセルはフラグメント内
          isFragment = (lightCount / area) >= lightCellRatio;
        } else {
          // 白背景: 黒ピクセルが一定以上あるセルはフラグメント内
          isFragment = (darkCount / area) >= lightCellRatio;
        }

        if (!isFragment) continue;

        const index = row * cols + col;
        grid[index] = 1;
        activeCells.push({
          row, col, x0, y0, x1, y1,
          cx: (x0 + x1) / 2,
          cy: (y0 + y1) / 2,
          weight: bgIsDark ? lightCount : darkCount,
        });
      }
    }

    return { grid, rows, cols, cellSize, activeCells };
  }

  // ---- Morphological closing（膨張 → 収縮）----

  function morphClose(grid, cols, rows, radius) {
    const dilated = morphDilate(grid, cols, rows, radius);
    return morphErode(dilated, cols, rows, radius);
  }

  function morphDilate(grid, cols, rows, radius) {
    const result = new Uint8Array(cols * rows);
    for (let r = 0; r < rows; r += 1) {
      for (let c = 0; c < cols; c += 1) {
        let found = false;
        for (let dr = -radius; dr <= radius && !found; dr += 1) {
          for (let dc = -radius; dc <= radius && !found; dc += 1) {
            const nr = r + dr;
            const nc = c + dc;
            if (nr >= 0 && nr < rows && nc >= 0 && nc < cols && grid[nr * cols + nc]) {
              found = true;
            }
          }
        }
        result[r * cols + c] = found ? 1 : 0;
      }
    }
    return result;
  }

  function morphErode(grid, cols, rows, radius) {
    const result = new Uint8Array(cols * rows);
    for (let r = 0; r < rows; r += 1) {
      for (let c = 0; c < cols; c += 1) {
        let allSet = true;
        for (let dr = -radius; dr <= radius && allSet; dr += 1) {
          for (let dc = -radius; dc <= radius && allSet; dc += 1) {
            const nr = r + dr;
            const nc = c + dc;
            if (nr < 0 || nr >= rows || nc < 0 || nc >= cols || !grid[nr * cols + nc]) {
              allSet = false;
            }
          }
        }
        result[r * cols + c] = allSet ? 1 : 0;
      }
    }
    return result;
  }

  // ---- Connected Components ----

  function findComponentBoxes(grid, rows, cols, cellSize, minCellCount, minBoxSize, imgWidth, imgHeight) {
    const visited = new Uint8Array(grid.length);
    const boxes = [];

    for (let r = 0; r < rows; r += 1) {
      for (let c = 0; c < cols; c += 1) {
        const idx = r * cols + c;
        if (!grid[idx] || visited[idx]) continue;

        // BFS
        const stack = [idx];
        visited[idx] = 1;
        let count = 0;
        let minRow = r, maxRow = r, minCol = c, maxCol = c;

        while (stack.length > 0) {
          const cur = stack.pop();
          const cr = Math.floor(cur / cols);
          const cc = cur % cols;
          count += 1;
          if (cr < minRow) minRow = cr;
          if (cr > maxRow) maxRow = cr;
          if (cc < minCol) minCol = cc;
          if (cc > maxCol) maxCol = cc;

          const neighbors = [[cr - 1, cc], [cr + 1, cc], [cr, cc - 1], [cr, cc + 1]];
          for (const [nr, nc] of neighbors) {
            if (nr < 0 || nr >= rows || nc < 0 || nc >= cols) continue;
            const ni = nr * cols + nc;
            if (!grid[ni] || visited[ni]) continue;
            visited[ni] = 1;
            stack.push(ni);
          }
        }

        if (count < minCellCount) continue;

        const x = minCol * cellSize;
        const y = minRow * cellSize;
        const w = Math.min(imgWidth, (maxCol + 1) * cellSize) - x;
        const h = Math.min(imgHeight, (maxRow + 1) * cellSize) - y;
        if (w < minBoxSize || h < minBoxSize) continue;

        boxes.push({ x, y, width: w, height: h, cellCount: count });
      }
    }

    return boxes;
  }

  // ---- コンテンツ境界 ----

  function computeBoundsFromCells(activeCells, imgWidth, imgHeight) {
    if (activeCells.length === 0) return null;

    let minX = imgWidth, minY = imgHeight, maxX = 0, maxY = 0;
    for (const cell of activeCells) {
      if (cell.x0 < minX) minX = cell.x0;
      if (cell.y0 < minY) minY = cell.y0;
      if (cell.x1 > maxX) maxX = cell.x1;
      if (cell.y1 > maxY) maxY = cell.y1;
    }

    if (maxX <= minX || maxY <= minY) return null;
    return { x: minX, y: minY, width: maxX - minX, height: maxY - minY };
  }

  // ---- k-means クラスタリング ----

  function kMeansClusterCells(activeCells, bounds, k, iterations) {
    if (!activeCells || activeCells.length === 0) return [];

    const clusters = Math.min(k, activeCells.length);
    // 4 隅で初期化
    const centroids = [
      { x: bounds.x, y: bounds.y },
      { x: bounds.x + bounds.width, y: bounds.y },
      { x: bounds.x, y: bounds.y + bounds.height },
      { x: bounds.x + bounds.width, y: bounds.y + bounds.height },
    ].slice(0, clusters);

    const assignments = new Int16Array(activeCells.length);

    for (let iter = 0; iter < iterations; iter += 1) {
      const sums = Array.from({ length: clusters }, () => ({ x: 0, y: 0, w: 0 }));

      for (let i = 0; i < activeCells.length; i += 1) {
        const cell = activeCells[i];
        let best = 0;
        let bestDist = Infinity;
        for (let c = 0; c < clusters; c += 1) {
          const dx = cell.cx - centroids[c].x;
          const dy = cell.cy - centroids[c].y;
          const dist = dx * dx + dy * dy;
          if (dist < bestDist) {
            bestDist = dist;
            best = c;
          }
        }
        assignments[i] = best;
        const w = Math.max(1, cell.weight);
        sums[best].x += cell.cx * w;
        sums[best].y += cell.cy * w;
        sums[best].w += w;
      }

      for (let c = 0; c < clusters; c += 1) {
        if (sums[c].w > 0) {
          centroids[c].x = sums[c].x / sums[c].w;
          centroids[c].y = sums[c].y / sums[c].w;
        }
      }
    }

    // クラスタごとのバウンディングボックスを算出
    const boxes = Array.from({ length: clusters }, () => ({
      minX: Infinity, minY: Infinity, maxX: -1, maxY: -1, count: 0,
    }));

    for (let i = 0; i < activeCells.length; i += 1) {
      const cell = activeCells[i];
      const box = boxes[assignments[i]];
      box.count += 1;
      if (cell.x0 < box.minX) box.minX = cell.x0;
      if (cell.y0 < box.minY) box.minY = cell.y0;
      if (cell.x1 > box.maxX) box.maxX = cell.x1;
      if (cell.y1 > box.maxY) box.maxY = cell.y1;
    }

    const results = [];
    for (const box of boxes) {
      if (box.count === 0 || box.maxX <= box.minX || box.maxY <= box.minY) continue;
      results.push({ x: box.minX, y: box.minY, width: box.maxX - box.minX, height: box.maxY - box.minY });
    }
    return results;
  }

  // ---- フォールバック: 4 等分 ----

  function fallbackQuadrants(bounds) {
    const hw = bounds.width / 2;
    const hh = bounds.height / 2;
    return [
      { x: bounds.x, y: bounds.y, width: hw, height: hh },
      { x: bounds.x + hw, y: bounds.y, width: hw, height: hh },
      { x: bounds.x, y: bounds.y + hh, width: hw, height: hh },
      { x: bounds.x + hw, y: bounds.y + hh, width: hw, height: hh },
    ];
  }

  // ---- 役割割り当て ----

  function assignRolesByCorners(boxes) {
    const centered = boxes.map((box) => ({
      box,
      cx: box.x + box.width / 2,
      cy: box.y + box.height / 2,
    }));

    let minCx = Infinity, minCy = Infinity, maxCx = -1, maxCy = -1;
    for (const b of centered) {
      if (b.cx < minCx) minCx = b.cx;
      if (b.cy < minCy) minCy = b.cy;
      if (b.cx > maxCx) maxCx = b.cx;
      if (b.cy > maxCy) maxCy = b.cy;
    }

    const corners = {
      TL: { x: minCx, y: minCy },
      TR: { x: maxCx, y: minCy },
      BL: { x: minCx, y: maxCy },
      BR: { x: maxCx, y: maxCy },
    };

    // 全順列で最適な割り当てを探索
    const perms = permutations([0, 1, 2, 3]);
    let bestScore = Infinity;
    let bestPerm = perms[0];

    for (const perm of perms) {
      let score = 0;
      for (let i = 0; i < ROLE_ORDER.length; i += 1) {
        const corner = corners[ROLE_ORDER[i]];
        const b = centered[perm[i]];
        const dx = b.cx - corner.x;
        const dy = b.cy - corner.y;
        score += dx * dx + dy * dy;
      }
      if (score < bestScore) {
        bestScore = score;
        bestPerm = perm;
      }
    }

    const roles = {};
    for (let i = 0; i < ROLE_ORDER.length; i += 1) {
      roles[ROLE_ORDER[i]] = centered[bestPerm[i]].box;
    }
    return roles;
  }

  function permutations(values) {
    const out = [];
    function walk(prefix, rest) {
      if (rest.length === 0) { out.push(prefix); return; }
      for (let i = 0; i < rest.length; i += 1) {
        const next = rest.slice();
        const v = next.splice(i, 1)[0];
        walk(prefix.concat(v), next);
      }
    }
    walk([], values);
    return out;
  }

  // ---- デバッグ画像描画 ----

  function drawRegionsDebugImage(binarizedImage, componentBoxes, roles) {
    const canvas = document.createElement("canvas");
    canvas.width = binarizedImage.width;
    canvas.height = binarizedImage.height;
    const ctx = canvas.getContext("2d");
    ctx.putImageData(binarizedImage, 0, 0);

    // Connected component のボックス（点線）
    ctx.lineWidth = 1;
    ctx.setLineDash([4, 3]);
    ctx.strokeStyle = "rgba(123, 143, 182, 0.6)";
    for (const box of componentBoxes) {
      ctx.strokeRect(box.x + 0.5, box.y + 0.5, box.width - 1, box.height - 1);
    }

    // 役割ごとのボックス（実線 + ラベル）
    ctx.setLineDash([]);
    for (const role of ROLE_ORDER) {
      const box = roles[role];
      if (!box) continue;

      ctx.lineWidth = 2;
      ctx.strokeStyle = ROLE_COLORS[role];
      ctx.strokeRect(box.x + 1, box.y + 1, Math.max(1, box.width - 2), Math.max(1, box.height - 2));

      ctx.fillStyle = "rgba(255, 255, 255, 0.92)";
      const lw = 26, lh = 14;
      ctx.fillRect(box.x + 2, box.y + 2, lw, lh);
      ctx.strokeStyle = ROLE_COLORS[role];
      ctx.lineWidth = 1;
      ctx.strokeRect(box.x + 2.5, box.y + 2.5, lw - 1, lh - 1);
      ctx.fillStyle = "#1f355f";
      ctx.font = "10px sans-serif";
      ctx.textBaseline = "middle";
      ctx.fillText(role, box.x + 7, box.y + 9);
    }

    return ctx.getImageData(0, 0, canvas.width, canvas.height);
  }

  // ---- ソース座標変換・結合 ----

  function toSourceBox(box, scaleX, scaleY, maxW, maxH, expandRatio) {
    const ex = box.width * expandRatio;
    const ey = box.height * expandRatio;
    const x = clamp(Math.floor((box.x - ex) * scaleX), 0, maxW - 1);
    const y = clamp(Math.floor((box.y - ey) * scaleY), 0, maxH - 1);
    const right = clamp(Math.ceil((box.x + box.width + ex) * scaleX), x + 1, maxW);
    const bottom = clamp(Math.ceil((box.y + box.height + ey) * scaleY), y + 1, maxH);
    return { x, y, width: Math.max(1, right - x), height: Math.max(1, bottom - y) };
  }

  function computeTargetSide(sourceBoxes) {
    const values = ROLE_ORDER.map((role) => {
      const b = sourceBoxes[role];
      return Math.max(b.width, b.height);
    });
    const avg = values.reduce((a, v) => a + v, 0) / Math.max(1, values.length);
    return clamp(Math.round(avg), 48, 1200);
  }

  function drawRoleCrop(ctx, sourceCanvas, box, dx, dy, dw, dh) {
    ctx.drawImage(sourceCanvas, box.x, box.y, box.width, box.height, dx, dy, dw, dh);
  }

  // ---- QR デコード ----

  function decodeWithJsQR(imageData) {
    if (typeof window.jsQR !== "function") return null;
    const result = window.jsQR(imageData.data, imageData.width, imageData.height, {
      inversionAttempts: "attemptBoth",
    });
    return (result && typeof result.data === "string" && result.data.length > 0) ? result.data : null;
  }

  // ---- エクスポート ----

  window.qrPipeline = {
    process,
    processWithDebug,
    getLastDebug,
  };
})();
