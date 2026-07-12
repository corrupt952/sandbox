(() => {
  "use strict";

  const ROLE_ORDER = ["TL", "TR", "BL", "BR"];
  const ROLE_LABEL = {
    TL: "Top-Left",
    TR: "Top-Right",
    BL: "Bottom-Left",
    BR: "Bottom-Right",
  };

  // 端末には「反対側の角」に表示し、4台を寄せると中央で合体する
  const ROLE_DISPLAY_CORNER = {
    TL: { bottom: "0mm", right: "0mm" },
    TR: { bottom: "0mm", left: "0mm" },
    BL: { top: "0mm", right: "0mm" },
    BR: { top: "0mm", left: "0mm" },
  };

  const DEFAULT_MODULE_MM = 1.2;
  const MIN_MODULE_MM = 0.6;
  const MAX_MODULE_MM = 2.5;
  const MIN_CALIBRATION = 0.9;
  const MAX_CALIBRATION = 1.1;
  const CALIBRATION_STORAGE_KEY = "qr-combine-calibration";

  document.addEventListener("DOMContentLoaded", () => {
    const page = document.body.dataset.page;
    if (page === "index") {
      initIndexPage();
      return;
    }

    if (page === "host") {
      initHostPage();
      return;
    }

    if (page === "display") {
      initDisplayPage();
      return;
    }

    if (page === "debug") {
      initDebugPage();
    }
  });

  function initIndexPage() {
    const createRoomBtn = document.getElementById("createRoomBtn");
    const joinForm = document.getElementById("joinForm");
    const roomCodeInput = document.getElementById("roomCodeInput");
    const indexError = document.getElementById("indexError");

    createRoomBtn?.addEventListener("click", () => {
      location.href = "/host.html";
    });

    joinForm?.addEventListener("submit", (event) => {
      event.preventDefault();
      const roomCode = normalizeRoomCode(roomCodeInput?.value);
      if (!roomCode) {
        indexError.textContent = "ルームコードを入力してください。";
        return;
      }

      location.href = `/display.html?room=${encodeURIComponent(roomCode)}`;
    });
  }

  function initHostPage() {
    const state = {
      ws: null,
      roomCode: "",
      clientId: "",
      role: "",
      qrText: "",
      participants: [],
      moduleMm: DEFAULT_MODULE_MM,
    };

    const els = {
      roomCodeLabel: document.getElementById("roomCodeLabel"),
      hostRoleLabel: document.getElementById("hostRoleLabel"),
      memberCount: document.getElementById("memberCount"),
      joinUrlInput: document.getElementById("joinUrlInput"),
      copyJoinUrlBtn: document.getElementById("copyJoinUrlBtn"),
      qrTextInput: document.getElementById("qrTextInput"),
      updateQrBtn: document.getElementById("updateQrBtn"),
      qrStatusLine: document.getElementById("qrStatusLine"),
      moduleMmRange: document.getElementById("moduleMmRange"),
      moduleMmNumber: document.getElementById("moduleMmNumber"),
      roleSlots: document.getElementById("roleSlots"),
      enterDisplayBtn: document.getElementById("enterDisplayBtn"),
      exitDisplayBtn: document.getElementById("exitDisplayBtn"),
      hostDisplaySurface: document.getElementById("hostDisplaySurface"),
      fragmentCanvas: document.getElementById("fragmentCanvas"),
      displayState: document.getElementById("displayState"),
      displayRoomCode: document.getElementById("displayRoomCode"),
      displayRole: document.getElementById("displayRole"),
    };

    const pushModuleSizeDebounced = debounce((nextValue) => {
      if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
        return;
      }
      sendMessage(state.ws, {
        type: "update_settings",
        moduleMm: nextValue,
      });
    }, 140);

    function setStatus(text, isError = false) {
      if (!els.qrStatusLine) {
        return;
      }
      els.qrStatusLine.textContent = text;
      els.qrStatusLine.style.color = isError ? "#cc304b" : "#5d6a82";
    }

    function updateHeaderUi() {
      if (els.roomCodeLabel) {
        els.roomCodeLabel.textContent = state.roomCode || "----";
      }

      if (els.hostRoleLabel) {
        els.hostRoleLabel.textContent = formatRoleLabel(state.role);
      }

      if (els.memberCount) {
        els.memberCount.textContent = `${state.participants.length} / 4`;
      }

      const joinUrl = state.roomCode
        ? `${location.origin}/display.html?room=${encodeURIComponent(state.roomCode)}`
        : "";
      if (els.joinUrlInput) {
        els.joinUrlInput.value = joinUrl;
      }

      if (els.displayRoomCode) {
        els.displayRoomCode.textContent = state.roomCode || "----";
      }
      if (els.displayRole) {
        els.displayRole.textContent = formatRoleLabel(state.role);
      }
    }

    function syncModuleInputs(nextValue) {
      const value = sanitizeModuleMm(nextValue).toFixed(2);
      if (els.moduleMmRange && document.activeElement !== els.moduleMmRange) {
        els.moduleMmRange.value = value;
      }
      if (els.moduleMmNumber && document.activeElement !== els.moduleMmNumber) {
        els.moduleMmNumber.value = value;
      }
    }

    function renderRoleSlots() {
      if (!els.roleSlots) {
        return;
      }

      els.roleSlots.innerHTML = "";
      for (const role of ROLE_ORDER) {
        const holder = state.participants.find((p) => p.role === role);
        const li = document.createElement("li");
        li.className = "slot-item";
        li.innerHTML = `<strong>${role}</strong> ${holder ? `${shortId(holder.clientId)}${holder.isHost ? " (host)" : ""}` : "空き"}`;
        els.roleSlots.appendChild(li);
      }
    }

    function renderHostFragment() {
      if (!els.fragmentCanvas) {
        return;
      }

      const ok = renderRoleFragment({
        canvas: els.fragmentCanvas,
        role: state.role,
        text: state.qrText,
        moduleMm: state.moduleMm,
        calibrationFactor: 1,
      });

      if (!els.displayState) {
        return;
      }

      if (!state.role) {
        els.displayState.textContent = "役割の割り当て待ち...";
        return;
      }

      if (!state.qrText) {
        els.displayState.textContent = "ホストがQR内容を入力すると表示されます";
        return;
      }

      els.displayState.textContent = ok ? "表示準備完了" : "QR生成エラー（文字数を減らしてください）";
    }

    function pullRoleFromParticipants() {
      if (!state.clientId || !Array.isArray(state.participants)) {
        return;
      }
      const me = state.participants.find((p) => p.clientId === state.clientId);
      if (me && me.role) {
        state.role = me.role;
      }
    }

    function applyRoomState(msg) {
      if (typeof msg.roomCode === "string") {
        state.roomCode = msg.roomCode;
      }
      state.qrText = typeof msg.qrText === "string" ? msg.qrText : "";
      state.moduleMm = sanitizeModuleMm(msg.moduleMm);
      state.participants = Array.isArray(msg.participants) ? msg.participants : [];
      pullRoleFromParticipants();

      if (els.qrTextInput && document.activeElement !== els.qrTextInput) {
        els.qrTextInput.value = state.qrText;
      }

      syncModuleInputs(state.moduleMm);
      updateHeaderUi();
      renderRoleSlots();
      renderHostFragment();
    }

    const ws = createSocket({
      onOpen: (socket) => {
        sendMessage(socket, { type: "create_room" });
        setStatus("ルーム作成中...");
      },
      onMessage: (msg) => {
        if (msg.type === "room_created") {
          state.roomCode = normalizeRoomCode(msg.roomCode);
          state.clientId = msg.clientId;
          state.role = msg.role;
          state.moduleMm = sanitizeModuleMm(msg.moduleMm);
          state.qrText = typeof msg.qrText === "string" ? msg.qrText : "";
          updateHeaderUi();
          syncModuleInputs(state.moduleMm);
          renderHostFragment();
          setStatus("ルームを作成しました。URLを共有してください。");
          return;
        }

        if (msg.type === "room_state") {
          applyRoomState(msg);
          return;
        }

        if (msg.type === "error") {
          setStatus(msg.message || "エラーが発生しました。", true);
          return;
        }

        if (msg.type === "room_closed") {
          setStatus(msg.message || "ルームが閉じられました。", true);
        }
      },
      onClose: () => {
        setStatus("接続が切断されました。ページを再読み込みしてください。", true);
      },
      onError: () => {
        setStatus("サーバー接続エラー", true);
      },
    });

    state.ws = ws;

    els.updateQrBtn?.addEventListener("click", () => {
      if (!state.ws || state.ws.readyState !== WebSocket.OPEN) {
        setStatus("未接続のため送信できません。", true);
        return;
      }
      const nextText = els.qrTextInput?.value ?? "";
      sendMessage(state.ws, { type: "update_qr", text: nextText });
      setStatus("QR内容を送信しました。");
    });

    els.qrTextInput?.addEventListener("keydown", (event) => {
      if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
        event.preventDefault();
        els.updateQrBtn?.click();
      }
    });

    const updateModuleMmFromUi = (rawValue) => {
      const sanitized = sanitizeModuleMm(rawValue);
      state.moduleMm = sanitized;
      syncModuleInputs(sanitized);
      renderHostFragment();
      pushModuleSizeDebounced(sanitized);
    };

    els.moduleMmRange?.addEventListener("input", (event) => {
      updateModuleMmFromUi(event.target.value);
    });

    els.moduleMmNumber?.addEventListener("input", (event) => {
      updateModuleMmFromUi(event.target.value);
    });

    els.copyJoinUrlBtn?.addEventListener("click", async () => {
      const text = els.joinUrlInput?.value || "";
      if (!text) {
        return;
      }

      try {
        await navigator.clipboard.writeText(text);
        setStatus("参加URLをコピーしました。");
      } catch (error) {
        setStatus("コピーできませんでした。手動でコピーしてください。", true);
      }
    });

    els.enterDisplayBtn?.addEventListener("click", () => {
      if (!state.role) {
        setStatus("役割が割り当てられるまで待ってください。", true);
        return;
      }
      document.body.classList.add("host-display-mode");
      els.hostDisplaySurface?.classList.remove("hidden");
      renderHostFragment();
    });

    els.exitDisplayBtn?.addEventListener("click", () => {
      document.body.classList.remove("host-display-mode");
      els.hostDisplaySurface?.classList.add("hidden");
    });
  }

  function initDisplayPage() {
    const params = new URLSearchParams(location.search);
    const roomCode = normalizeRoomCode(params.get("room"));
    if (!roomCode) {
      location.href = "/";
      return;
    }

    const state = {
      ws: null,
      roomCode,
      clientId: "",
      role: "",
      qrText: "",
      participants: [],
      moduleMm: DEFAULT_MODULE_MM,
      calibrationFactor: loadCalibrationFactor(),
      roomClosed: false,
    };

    const els = {
      roomCodeLabel: document.getElementById("roomCodeLabel"),
      roleLabel: document.getElementById("roleLabel"),
      displayState: document.getElementById("displayState"),
      fragmentCanvas: document.getElementById("fragmentCanvas"),
      displayControls: document.getElementById("displayControls"),
      toggleOverlayBtn: document.getElementById("toggleOverlayBtn"),
      showOverlayBtn: document.getElementById("showOverlayBtn"),
      calibrationRange: document.getElementById("calibrationRange"),
      calibrationValue: document.getElementById("calibrationValue"),
    };

    if (els.roomCodeLabel) {
      els.roomCodeLabel.textContent = state.roomCode;
    }

    if (els.calibrationRange) {
      els.calibrationRange.value = state.calibrationFactor.toFixed(3);
    }
    if (els.calibrationValue) {
      els.calibrationValue.textContent = state.calibrationFactor.toFixed(3);
    }

    function setDisplayMessage(text, isError = false) {
      if (!els.displayState) {
        return;
      }
      els.displayState.textContent = text;
      els.displayState.style.color = isError ? "#c22644" : "#455472";
    }

    function pullRoleFromParticipants() {
      if (!state.clientId || !Array.isArray(state.participants)) {
        return;
      }
      const me = state.participants.find((p) => p.clientId === state.clientId);
      if (me) {
        state.role = me.role || "";
      }
    }

    function renderDisplay() {
      if (els.roleLabel) {
        els.roleLabel.textContent = formatRoleLabel(state.role);
      }

      if (state.roomClosed) {
        setDisplayMessage("ホストが切断されたためルームが終了しました。", true);
        return;
      }

      const ok = renderRoleFragment({
        canvas: els.fragmentCanvas,
        role: state.role,
        text: state.qrText,
        moduleMm: state.moduleMm,
        calibrationFactor: state.calibrationFactor,
      });

      if (!state.role) {
        setDisplayMessage("役割の割り当て待ち...");
        return;
      }

      if (!state.qrText) {
        setDisplayMessage("ホストがQR内容を入力するまで待機中...");
        return;
      }

      if (!ok) {
        setDisplayMessage("QR生成エラー（文字数が多すぎる可能性）", true);
        return;
      }

      setDisplayMessage("");
    }

    function applyRoomState(msg) {
      state.roomCode = normalizeRoomCode(msg.roomCode) || state.roomCode;
      state.qrText = typeof msg.qrText === "string" ? msg.qrText : "";
      state.moduleMm = sanitizeModuleMm(msg.moduleMm);
      state.participants = Array.isArray(msg.participants) ? msg.participants : [];
      pullRoleFromParticipants();

      if (els.roomCodeLabel) {
        els.roomCodeLabel.textContent = state.roomCode;
      }

      renderDisplay();
    }

    const ws = createSocket({
      onOpen: (socket) => {
        sendMessage(socket, { type: "join_room", roomCode: state.roomCode });
        setDisplayMessage("ルーム参加中...");
      },
      onMessage: (msg) => {
        if (msg.type === "room_joined") {
          state.clientId = msg.clientId;
          state.role = msg.role || state.role;
          state.qrText = typeof msg.qrText === "string" ? msg.qrText : state.qrText;
          state.moduleMm = sanitizeModuleMm(msg.moduleMm);
          state.roomClosed = false;
          renderDisplay();
          return;
        }

        if (msg.type === "room_state") {
          state.roomClosed = false;
          applyRoomState(msg);
          return;
        }

        if (msg.type === "room_closed") {
          state.roomClosed = true;
          renderDisplay();
          return;
        }

        if (msg.type === "error") {
          state.roomClosed = true;
          setDisplayMessage(msg.message || "エラーが発生しました。", true);
        }
      },
      onClose: () => {
        if (!state.roomClosed) {
          setDisplayMessage("接続が切れました。再読み込みしてください。", true);
        }
      },
      onError: () => {
        setDisplayMessage("サーバー接続エラー", true);
      },
    });

    state.ws = ws;

    els.calibrationRange?.addEventListener("input", (event) => {
      const next = clampNumber(Number(event.target.value), MIN_CALIBRATION, MAX_CALIBRATION);
      state.calibrationFactor = next;
      if (els.calibrationValue) {
        els.calibrationValue.textContent = next.toFixed(3);
      }
      saveCalibrationFactor(next);
      renderDisplay();
    });

    els.toggleOverlayBtn?.addEventListener("click", () => {
      els.displayControls?.classList.add("hidden");
      els.showOverlayBtn?.classList.remove("hidden");
    });

    els.showOverlayBtn?.addEventListener("click", () => {
      els.displayControls?.classList.remove("hidden");
      els.showOverlayBtn?.classList.add("hidden");
    });
  }

  function initDebugPage() {
    const SCAN_INTERVAL_MS = 200;
    const DEFAULT_SIM_CANVAS_SIZE = 640;
    const MIN_SIM_CANVAS_SIZE = 420;
    const MAX_SIM_CANVAS_SIZE = 3200;

    const state = {
      moduleMm: DEFAULT_MODULE_MM,
      gapPx: 0,
      showLabels: true,
      mmToPx: measureMmToPx(),
      qrReady: false,
      scanTimer: null,
      canvasWidth: DEFAULT_SIM_CANVAS_SIZE,
      canvasHeight: DEFAULT_SIM_CANVAS_SIZE,
      dragging: {
        pointerId: null,
        fragment: null,
        offsetX: 0,
        offsetY: 0,
      },
      fragments: [
        { role: "TL", x: 0, y: 0, width: 0, height: 0, imageData: null, imageCanvas: null, dragging: false },
        { role: "TR", x: 0, y: 0, width: 0, height: 0, imageData: null, imageCanvas: null, dragging: false },
        { role: "BL", x: 0, y: 0, width: 0, height: 0, imageData: null, imageCanvas: null, dragging: false },
        { role: "BR", x: 0, y: 0, width: 0, height: 0, imageData: null, imageCanvas: null, dragging: false },
      ],
    };

    const els = {
      debugQrTextInput: document.getElementById("debugQrTextInput"),
      debugModuleMmRange: document.getElementById("debugModuleMmRange"),
      debugModuleMmNumber: document.getElementById("debugModuleMmNumber"),
      debugGapRange: document.getElementById("debugGapRange"),
      debugGapValue: document.getElementById("debugGapValue"),
      debugShowLabelsToggle: document.getElementById("debugShowLabelsToggle"),
      debugStatus: document.getElementById("debugStatus"),
      debugSimCanvas: document.getElementById("debugSimCanvas"),
      debugResetPositionsBtn: document.getElementById("debugResetPositionsBtn"),
      debugScanResult: document.getElementById("debugScanResult"),
      debugScanDot: document.getElementById("debugScanDot"),
      debugScanText: document.getElementById("debugScanText"),
      togglePipelineBtn: document.getElementById("togglePipelineBtn"),
      pipelineDebug: document.getElementById("pipelineDebug"),
      pipelineBinarized: document.getElementById("pipelineBinarized"),
      pipelineRegions: document.getElementById("pipelineRegions"),
      pipelineCombined: document.getElementById("pipelineCombined"),
      debugFullCanvas: document.getElementById("debugFullCanvas"),
    };

    const simCtx = els.debugSimCanvas?.getContext("2d", { willReadFrequently: true });
    if (!els.debugSimCanvas || !simCtx) {
      return;
    }

    configureSimulationCanvas(DEFAULT_SIM_CANVAS_SIZE, DEFAULT_SIM_CANVAS_SIZE);
    drawBlankSimulation();

    function setStatus(text, isError = false) {
      if (!els.debugStatus) {
        return;
      }
      els.debugStatus.textContent = text;
      els.debugStatus.style.color = isError ? "#c22644" : "#5d6a82";
    }

    function setScanResult(ok, text) {
      if (els.debugScanResult) {
        els.debugScanResult.classList.toggle("success", ok);
        els.debugScanResult.classList.toggle("fail", !ok);
      }
      if (els.debugScanDot) {
        els.debugScanDot.style.background = ok ? "#31aa55" : "#cf3c3c";
      }
      if (els.debugScanText) {
        els.debugScanText.textContent = ok ? text : "読み取り不可";
      }
    }

    function setPipelineDebugOpen(open) {
      if (els.pipelineDebug) {
        els.pipelineDebug.classList.toggle("hidden", !open);
      }
      if (els.togglePipelineBtn) {
        els.togglePipelineBtn.textContent = open ? "パイプライン詳細を隠す" : "パイプライン詳細を表示";
      }
    }

    function clearPipelineCanvas(canvas) {
      if (!canvas) {
        return;
      }
      canvas.width = 1;
      canvas.height = 1;
      canvas.style.width = "0";
      canvas.style.height = "0";
    }

    function drawPipelineCanvas(canvas, imageData) {
      if (!canvas) {
        return;
      }
      if (!imageData || !imageData.data || !imageData.width || !imageData.height) {
        clearPipelineCanvas(canvas);
        return;
      }

      canvas.width = imageData.width;
      canvas.height = imageData.height;
      const ctx = canvas.getContext("2d");
      ctx.imageSmoothingEnabled = false;
      ctx.putImageData(imageData, 0, 0);

      const previewMax = 220;
      const scale = Math.min(1, previewMax / Math.max(imageData.width, imageData.height));
      canvas.style.width = `${Math.round(imageData.width * scale)}px`;
      canvas.style.height = `${Math.round(imageData.height * scale)}px`;
    }

    function renderPipelineDebug(debug) {
      if (!debug) {
        clearPipelineCanvas(els.pipelineBinarized);
        clearPipelineCanvas(els.pipelineRegions);
        clearPipelineCanvas(els.pipelineCombined);
        return;
      }

      drawPipelineCanvas(els.pipelineBinarized, debug.binarized);
      drawPipelineCanvas(els.pipelineRegions, debug.regions);
      drawPipelineCanvas(els.pipelineCombined, debug.combined);
    }

    function syncModuleInputs(nextValue) {
      const value = sanitizeModuleMm(nextValue).toFixed(2);
      if (els.debugModuleMmRange && document.activeElement !== els.debugModuleMmRange) {
        els.debugModuleMmRange.value = value;
      }
      if (els.debugModuleMmNumber && document.activeElement !== els.debugModuleMmNumber) {
        els.debugModuleMmNumber.value = value;
      }
    }

    function syncGapUi(nextValue) {
      const clamped = Math.round(clampNumber(Number(nextValue), 0, 20));
      if (els.debugGapRange && document.activeElement !== els.debugGapRange) {
        els.debugGapRange.value = String(clamped);
      }
      if (els.debugGapValue) {
        els.debugGapValue.textContent = `${clamped}px`;
      }
      return clamped;
    }

    function clearSimpleCanvas(canvas) {
      if (!canvas) return;
      canvas.width = 1;
      canvas.height = 1;
      canvas.style.width = "0";
      canvas.style.height = "0";
    }

    function measureMmToPx() {
      const probe = document.createElement("div");
      probe.style.position = "absolute";
      probe.style.visibility = "hidden";
      probe.style.left = "-9999px";
      probe.style.width = "100mm";
      document.body.appendChild(probe);
      const mmToPx = probe.getBoundingClientRect().width / 100;
      probe.remove();
      if (!Number.isFinite(mmToPx) || mmToPx <= 0) {
        return 3.7795275591;
      }
      return mmToPx;
    }

    function configureSimulationCanvas(width, height) {
      state.canvasWidth = Math.round(width);
      state.canvasHeight = Math.round(height);
      els.debugSimCanvas.width = state.canvasWidth;
      els.debugSimCanvas.height = state.canvasHeight;
      els.debugSimCanvas.style.width = `${state.canvasWidth}px`;
      els.debugSimCanvas.style.height = `${state.canvasHeight}px`;
    }

    function drawBlankSimulation() {
      simCtx.save();
      simCtx.imageSmoothingEnabled = false;
      // 背景を黒にして、実際のベゼル間の隙間（机・ベゼル色）をシミュレート
      simCtx.fillStyle = "#000000";
      simCtx.fillRect(0, 0, els.debugSimCanvas.width, els.debugSimCanvas.height);
      simCtx.restore();
    }

    function clearFragments() {
      for (const fragment of state.fragments) {
        fragment.imageData = null;
        fragment.imageCanvas = null;
        fragment.width = 0;
        fragment.height = 0;
        fragment.x = 0;
        fragment.y = 0;
        fragment.dragging = false;
      }
    }

    function buildFragmentImages(fullQr) {
      const halfWidth = fullQr.canvas.width / 2;
      const halfHeight = fullQr.canvas.height / 2;
      const totalDisplayPx = fullQr.totalModules * state.moduleMm * state.mmToPx;
      const fragmentDisplayPx = totalDisplayPx / 2;

      const margin = Math.max(30, Math.round(fragmentDisplayPx * 0.35));
      const desiredSize = Math.round(fragmentDisplayPx * 2 + state.gapPx + margin * 2);
      const simSize = clampNumber(desiredSize, MIN_SIM_CANVAS_SIZE, MAX_SIM_CANVAS_SIZE);
      configureSimulationCanvas(simSize, simSize);

      for (const fragment of state.fragments) {
        const source = getRoleSourceRect(fragment.role, halfWidth, halfHeight);
        if (!source) {
          fragment.imageData = null;
          fragment.imageCanvas = null;
          continue;
        }

        const tempCanvas = document.createElement("canvas");
        tempCanvas.width = halfWidth;
        tempCanvas.height = halfHeight;
        const tempCtx = tempCanvas.getContext("2d");
        tempCtx.imageSmoothingEnabled = false;
        tempCtx.drawImage(fullQr.canvas, source.sx, source.sy, halfWidth, halfHeight, 0, 0, halfWidth, halfHeight);

        fragment.imageData = tempCtx.getImageData(0, 0, halfWidth, halfHeight);
        fragment.imageCanvas = tempCanvas;
        fragment.width = Math.round(fragmentDisplayPx);
        fragment.height = Math.round(fragmentDisplayPx);
      }

      return { totalDisplayPx };
    }

    function resetPositions() {
      if (!state.qrReady) {
        return;
      }

      const size = state.fragments[0]?.width || 0;
      const totalSpan = size * 2 + state.gapPx;
      const startX = (state.canvasWidth - totalSpan) / 2;
      const startY = (state.canvasHeight - totalSpan) / 2;
      const rolePosition = {
        TL: { x: startX, y: startY },
        TR: { x: startX + size + state.gapPx, y: startY },
        BL: { x: startX, y: startY + size + state.gapPx },
        BR: { x: startX + size + state.gapPx, y: startY + size + state.gapPx },
      };

      for (const fragment of state.fragments) {
        const pos = rolePosition[fragment.role];
        fragment.x = pos?.x ?? 0;
        fragment.y = pos?.y ?? 0;
        fragment.dragging = false;
      }

      state.dragging.pointerId = null;
      state.dragging.fragment = null;
      els.debugSimCanvas.classList.remove("dragging");
      drawCompositeCanvas();
      runScanOnce();
    }

    function drawFragmentLabel(fragment) {
      const labelX = fragment.x + 7;
      const labelY = fragment.y + 7;
      const text = fragment.role;

      simCtx.save();
      simCtx.font = "12px 'Avenir Next', 'Hiragino Sans', sans-serif";
      simCtx.textBaseline = "top";
      const metrics = simCtx.measureText(text);
      const tagWidth = Math.ceil(metrics.width) + 12;
      const tagHeight = 20;
      simCtx.fillStyle = "rgba(255, 255, 255, 0.88)";
      simCtx.strokeStyle = "#c7d6ee";
      simCtx.lineWidth = 1;
      simCtx.beginPath();
      simCtx.rect(labelX, labelY, tagWidth, tagHeight);
      simCtx.fill();
      simCtx.stroke();
      simCtx.fillStyle = "#4a628e";
      simCtx.fillText(text, labelX + 6, labelY + 4);
      simCtx.restore();
    }

    // ラベルやドラッグ枠なしの「クリーンな」QR画像だけを描画する（スキャン用）
    function drawCleanComposite() {
      drawBlankSimulation();
      for (const fragment of state.fragments) {
        if (!fragment.imageCanvas) {
          continue;
        }
        simCtx.drawImage(fragment.imageCanvas, fragment.x, fragment.y, fragment.width, fragment.height);
      }
    }

    // ラベル・ドラッグ枠などのオーバーレイを追加描画する（表示用）
    function drawOverlay() {
      const isDragging = Boolean(state.dragging.fragment);
      for (const fragment of state.fragments) {
        if (!fragment.imageCanvas) {
          continue;
        }

        if (isDragging) {
          simCtx.save();
          simCtx.lineWidth = 1;
          simCtx.setLineDash([6, 4]);
          simCtx.strokeStyle = fragment.dragging ? "rgba(12, 102, 212, 0.78)" : "rgba(67, 103, 160, 0.32)";
          simCtx.strokeRect(fragment.x + 0.5, fragment.y + 0.5, fragment.width - 1, fragment.height - 1);
          simCtx.restore();
        }

        if (state.showLabels) {
          drawFragmentLabel(fragment);
        }
      }
    }

    function drawCompositeCanvas() {
      drawCleanComposite();
      drawOverlay();
    }

    function updateFullQrCanvas(fullQr, totalDisplayPx) {
      if (!els.debugFullCanvas) {
        return;
      }

      els.debugFullCanvas.width = fullQr.canvas.width;
      els.debugFullCanvas.height = fullQr.canvas.height;
      const fullCtx = els.debugFullCanvas.getContext("2d");
      fullCtx.imageSmoothingEnabled = false;
      fullCtx.clearRect(0, 0, fullQr.canvas.width, fullQr.canvas.height);
      fullCtx.drawImage(fullQr.canvas, 0, 0);
      els.debugFullCanvas.style.width = `${totalDisplayPx.toFixed(3)}px`;
      els.debugFullCanvas.style.height = `${totalDisplayPx.toFixed(3)}px`;
    }

    function renderFromInput() {
      const text = String(els.debugQrTextInput?.value ?? "").trim();
      if (!text) {
        clearFragments();
        state.qrReady = false;
        configureSimulationCanvas(DEFAULT_SIM_CANVAS_SIZE, DEFAULT_SIM_CANVAS_SIZE);
        drawBlankSimulation();
        clearSimpleCanvas(els.debugFullCanvas);
        setScanResult(false, "読み取り不可");
        renderPipelineDebug(null);
        setStatus("QRコンテンツを入力してください。");
        return;
      }

      if (typeof qrcode !== "function") {
        setStatus("QRライブラリの読み込み待ちです。", true);
        setScanResult(false, "読み取り不可");
        renderPipelineDebug(null);
        return;
      }

      let fullQr = null;
      try {
        fullQr = buildFullQrCanvas(text);
      } catch (error) {
        clearFragments();
        state.qrReady = false;
        drawBlankSimulation();
        clearSimpleCanvas(els.debugFullCanvas);
        setScanResult(false, "読み取り不可");
        renderPipelineDebug(null);
        setStatus("QR生成に失敗しました。入力文字数を減らしてください。", true);
        return;
      }

      const { totalDisplayPx } = buildFragmentImages(fullQr);
      state.qrReady = true;
      resetPositions();
      updateFullQrCanvas(fullQr, totalDisplayPx);
      setStatus(`表示中: module ${state.moduleMm.toFixed(2)}mm / gap ${state.gapPx}px`);
    }

    function hitTest(x, y) {
      for (let i = state.fragments.length - 1; i >= 0; i -= 1) {
        const fragment = state.fragments[i];
        if (!fragment.imageCanvas) {
          continue;
        }
        const insideX = x >= fragment.x && x <= fragment.x + fragment.width;
        const insideY = y >= fragment.y && y <= fragment.y + fragment.height;
        if (insideX && insideY) {
          return fragment;
        }
      }
      return null;
    }

    function getPointerPoint(event) {
      const rect = els.debugSimCanvas.getBoundingClientRect();
      const scaleX = els.debugSimCanvas.width / rect.width;
      const scaleY = els.debugSimCanvas.height / rect.height;
      return {
        x: (event.clientX - rect.left) * scaleX,
        y: (event.clientY - rect.top) * scaleY,
      };
    }

    function onPointerDown(event) {
      if (!state.qrReady) {
        return;
      }

      const point = getPointerPoint(event);
      const hit = hitTest(point.x, point.y);
      if (!hit) {
        return;
      }

      event.preventDefault();
      if (typeof els.debugSimCanvas.setPointerCapture === "function") {
        els.debugSimCanvas.setPointerCapture(event.pointerId);
      }

      const hitIndex = state.fragments.indexOf(hit);
      if (hitIndex >= 0) {
        state.fragments.splice(hitIndex, 1);
        state.fragments.push(hit);
      }

      state.dragging.pointerId = event.pointerId;
      state.dragging.fragment = hit;
      state.dragging.offsetX = point.x - hit.x;
      state.dragging.offsetY = point.y - hit.y;
      hit.dragging = true;
      els.debugSimCanvas.classList.add("dragging");
      drawCompositeCanvas();
    }

    function onPointerMove(event) {
      if (state.dragging.pointerId !== event.pointerId || !state.dragging.fragment) {
        return;
      }

      event.preventDefault();
      const fragment = state.dragging.fragment;
      const point = getPointerPoint(event);
      const nextX = point.x - state.dragging.offsetX;
      const nextY = point.y - state.dragging.offsetY;
      fragment.x = clampNumber(nextX, 0, state.canvasWidth - fragment.width);
      fragment.y = clampNumber(nextY, 0, state.canvasHeight - fragment.height);
      drawCompositeCanvas();
    }

    function endDragging(pointerId) {
      if (state.dragging.pointerId !== pointerId) {
        return;
      }

      if (state.dragging.fragment) {
        state.dragging.fragment.dragging = false;
      }

      state.dragging.pointerId = null;
      state.dragging.fragment = null;
      state.dragging.offsetX = 0;
      state.dragging.offsetY = 0;
      els.debugSimCanvas.classList.remove("dragging");
      drawCompositeCanvas();
      runScanOnce();
    }

    function runScanOnce() {
      if (!state.qrReady) {
        setScanResult(false, "読み取り不可");
        renderPipelineDebug(null);
        return;
      }

      // ラベル・枠線なしのクリーン描画でスキャンし、その後オーバーレイを戻す
      drawCleanComposite();
      let imageData = null;
      try {
        imageData = simCtx.getImageData(0, 0, els.debugSimCanvas.width, els.debugSimCanvas.height);
      } catch (error) {
        drawOverlay();
        setScanResult(false, "読み取り不可");
        renderPipelineDebug(null);
        return;
      }
      drawOverlay();

      if (window.qrPipeline && typeof window.qrPipeline.process === "function") {
        try {
          const text = window.qrPipeline.process(imageData);
          const debug = typeof window.qrPipeline.getLastDebug === "function" ? window.qrPipeline.getLastDebug() : null;
          renderPipelineDebug(debug);
          if (text) {
            setScanResult(true, text);
            return;
          }
          setScanResult(false, "読み取り不可");
          return;
        } catch (error) {
          setStatus("パイプライン処理でエラーが発生しました。", true);
          setScanResult(false, "読み取り不可");
          renderPipelineDebug(null);
          return;
        }
      }

      // qr-pipeline.jsが未ロード時の安全なフォールバック
      if (typeof jsQR !== "function") {
        setStatus("qr-pipeline.js / jsQR の読み込み待ちです。", true);
        setScanResult(false, "読み取り不可");
        renderPipelineDebug(null);
        return;
      }

      const fallback = jsQR(imageData.data, imageData.width, imageData.height, {
        inversionAttempts: "attemptBoth",
      });
      if (fallback && typeof fallback.data === "string" && fallback.data.length > 0) {
        setScanResult(true, fallback.data);
      } else {
        setScanResult(false, "読み取り不可");
      }
      renderPipelineDebug(null);
    }

    function startScanLoop() {
      if (state.scanTimer) {
        clearInterval(state.scanTimer);
      }
      state.scanTimer = window.setInterval(runScanOnce, SCAN_INTERVAL_MS);
    }

    function stopScanLoop() {
      if (state.scanTimer) {
        clearInterval(state.scanTimer);
        state.scanTimer = null;
      }
    }

    els.debugQrTextInput?.addEventListener("input", () => {
      renderFromInput();
    });

    const onModuleMmInput = (rawValue) => {
      state.moduleMm = sanitizeModuleMm(rawValue);
      syncModuleInputs(state.moduleMm);
      renderFromInput();
    };

    els.debugModuleMmRange?.addEventListener("input", (event) => {
      onModuleMmInput(event.target.value);
    });

    els.debugModuleMmNumber?.addEventListener("input", (event) => {
      onModuleMmInput(event.target.value);
    });

    els.debugGapRange?.addEventListener("input", (event) => {
      state.gapPx = syncGapUi(event.target.value);
      if (state.qrReady) {
        resetPositions();
        setStatus(`表示中: module ${state.moduleMm.toFixed(2)}mm / gap ${state.gapPx}px`);
        return;
      }
      setStatus("QRコンテンツを入力してください。");
    });

    els.debugShowLabelsToggle?.addEventListener("change", (event) => {
      state.showLabels = Boolean(event.target.checked);
      drawCompositeCanvas();
    });

    els.debugResetPositionsBtn?.addEventListener("click", () => {
      resetPositions();
    });

    els.togglePipelineBtn?.addEventListener("click", () => {
      const currentlyOpen = !els.pipelineDebug?.classList.contains("hidden");
      setPipelineDebugOpen(!currentlyOpen);
    });

    els.debugSimCanvas.addEventListener("pointerdown", onPointerDown);
    els.debugSimCanvas.addEventListener("pointermove", onPointerMove);
    els.debugSimCanvas.addEventListener("pointerup", (event) => endDragging(event.pointerId));
    els.debugSimCanvas.addEventListener("pointercancel", (event) => endDragging(event.pointerId));

    window.addEventListener(
      "beforeunload",
      () => {
        stopScanLoop();
      },
      { once: true },
    );

    syncModuleInputs(state.moduleMm);
    state.gapPx = syncGapUi(0);
    state.showLabels = Boolean(els.debugShowLabelsToggle?.checked ?? true);
    setPipelineDebugOpen(false);
    renderPipelineDebug(null);
    startScanLoop();
    renderFromInput();
  }

  function createSocket({ onOpen, onMessage, onClose, onError }) {
    const ws = new WebSocket(getWebSocketUrl());
    ws.addEventListener("open", () => {
      if (typeof onOpen === "function") {
        onOpen(ws);
      }
    });

    ws.addEventListener("message", (event) => {
      let msg;
      try {
        msg = JSON.parse(event.data);
      } catch (error) {
        return;
      }
      if (typeof onMessage === "function") {
        onMessage(msg);
      }
    });

    ws.addEventListener("close", () => {
      if (typeof onClose === "function") {
        onClose();
      }
    });

    ws.addEventListener("error", () => {
      if (typeof onError === "function") {
        onError();
      }
    });

    return ws;
  }

  function sendMessage(ws, payload) {
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      return;
    }
    ws.send(JSON.stringify(payload));
  }

  function getWebSocketUrl() {
    const protocol = location.protocol === "https:" ? "wss:" : "ws:";
    return `${protocol}//${location.host}/ws`;
  }

  function normalizeRoomCode(input) {
    return String(input || "").trim().toUpperCase();
  }

  function shortId(id) {
    return String(id || "").slice(0, 6) || "------";
  }

  function formatRoleLabel(role) {
    return role && ROLE_LABEL[role] ? `${role} (${ROLE_LABEL[role]})` : "--";
  }

  function sanitizeModuleMm(value) {
    const num = Number(value);
    if (!Number.isFinite(num)) {
      return DEFAULT_MODULE_MM;
    }
    return clampNumber(num, MIN_MODULE_MM, MAX_MODULE_MM);
  }

  function clampNumber(value, min, max) {
    return Math.max(min, Math.min(max, value));
  }

  function debounce(fn, waitMs) {
    let timer = null;
    return (...args) => {
      if (timer) {
        clearTimeout(timer);
      }
      timer = setTimeout(() => fn(...args), waitMs);
    };
  }

  function loadCalibrationFactor() {
    try {
      const raw = localStorage.getItem(CALIBRATION_STORAGE_KEY);
      if (!raw) {
        return 1;
      }
      return clampNumber(Number(raw), MIN_CALIBRATION, MAX_CALIBRATION);
    } catch (error) {
      return 1;
    }
  }

  function saveCalibrationFactor(value) {
    try {
      localStorage.setItem(CALIBRATION_STORAGE_KEY, String(value));
    } catch (error) {
      // localStorage失敗時は何もしない
    }
  }

  function renderRoleFragment({ canvas, role, text, moduleMm, calibrationFactor }) {
    if (!canvas) {
      return false;
    }

    if (!role || !text) {
      canvas.width = 1;
      canvas.height = 1;
      canvas.style.width = "0";
      canvas.style.height = "0";
      return false;
    }

    if (typeof qrcode !== "function") {
      return false;
    }

    let fullQr;
    try {
      fullQr = buildFullQrCanvas(text);
    } catch (error) {
      return false;
    }

    const halfWidth = fullQr.canvas.width / 2;
    const halfHeight = fullQr.canvas.height / 2;
    const source = getRoleSourceRect(role, halfWidth, halfHeight);
    if (!source) {
      return false;
    }

    canvas.width = halfWidth;
    canvas.height = halfHeight;

    const ctx = canvas.getContext("2d");
    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, halfWidth, halfHeight);
    ctx.drawImage(fullQr.canvas, source.sx, source.sy, halfWidth, halfHeight, 0, 0, halfWidth, halfHeight);

    // 表示サイズはmm単位で固定し、端末差を減らす
    const totalMm = fullQr.totalModules * sanitizeModuleMm(moduleMm) * calibrationFactor;
    const fragmentMm = totalMm / 2;

    canvas.style.width = `${fragmentMm.toFixed(3)}mm`;
    canvas.style.height = `${fragmentMm.toFixed(3)}mm`;
    placeFragmentCanvasByRole(canvas, role);
    return true;
  }

  function buildFullQrCanvas(text) {
    // Error Correction Level H (約30%復元) を固定
    const qr = qrcode(0, "H");
    qr.addData(text);
    qr.make();

    const minQuietZone = 4;
    const moduleCount = qr.getModuleCount(); // 常に奇数 (4*ver+17)
    const rawTotal = moduleCount + minQuietZone * 2;
    // totalModulesを偶数にして、4分割時にモジュール境界で切れるようにする
    const totalModules = rawTotal + (rawTotal % 2);
    // QRコードを中央配置するためのオフセット（左右で quiet zone が非対称になる場合がある）
    const quietLeft = Math.floor((totalModules - moduleCount) / 2);
    const quietTop = quietLeft;

    const pxPerModule = 8;
    const sizePx = totalModules * pxPerModule;

    const canvas = document.createElement("canvas");
    canvas.width = sizePx;
    canvas.height = sizePx;

    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, sizePx, sizePx);

    ctx.fillStyle = "#000000";
    for (let row = 0; row < moduleCount; row += 1) {
      for (let col = 0; col < moduleCount; col += 1) {
        if (!qr.isDark(row, col)) {
          continue;
        }

        const x = (col + quietLeft) * pxPerModule;
        const y = (row + quietTop) * pxPerModule;
        ctx.fillRect(x, y, pxPerModule, pxPerModule);
      }
    }

    return {
      canvas,
      totalModules,
    };
  }

  function getRoleSourceRect(role, halfWidth, halfHeight) {
    switch (role) {
      case "TL":
        return { sx: 0, sy: 0 };
      case "TR":
        return { sx: halfWidth, sy: 0 };
      case "BL":
        return { sx: 0, sy: halfHeight };
      case "BR":
        return { sx: halfWidth, sy: halfHeight };
      default:
        return null;
    }
  }

  function placeFragmentCanvasByRole(canvas, role) {
    canvas.style.top = "auto";
    canvas.style.right = "auto";
    canvas.style.bottom = "auto";
    canvas.style.left = "auto";

    const corner = ROLE_DISPLAY_CORNER[role];
    if (!corner) {
      return;
    }

    if (corner.top) canvas.style.top = corner.top;
    if (corner.right) canvas.style.right = corner.right;
    if (corner.bottom) canvas.style.bottom = corner.bottom;
    if (corner.left) canvas.style.left = corner.left;
  }
})();
