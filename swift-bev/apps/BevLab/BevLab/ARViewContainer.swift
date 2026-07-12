//
//  ARViewContainer.swift
//  BevLab
//
//  Created by K@zuki. on 2026/07/12.
//

import ARKit
import IPMCore
import SceneKit
import SwiftUI

/// Wraps an `ARSCNView` that shares `BEVViewModel`'s `ARSession`, so the
/// live camera feed and plane visualization render through ARKit/SceneKit
/// directly rather than being re-rendered by SwiftUI every frame.
struct ARViewContainer: UIViewRepresentable {
  var viewModel: BEVViewModel

  func makeUIView(context: Context) -> ARSCNView {
    let arView = ARSCNView(frame: .zero)
    arView.session = viewModel.session
    arView.delegate = context.coordinator
    arView.automaticallyUpdatesLighting = true
    arView.scene = SCNScene()
    context.coordinator.arView = arView
    return arView
  }

  func updateUIView(_ uiView: ARSCNView, context: Context) {
    context.coordinator.update(groundRect: viewModel.currentGroundRect)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  /// Renders plane visualizations and the projected ground-rectangle
  /// outline as SceneKit nodes.
  final class Coordinator: NSObject, ARSCNViewDelegate {
    weak var arView: ARSCNView?
    private var groundRectNode: SCNNode?

    /// Rebuilds the ground-rectangle outline node from the latest
    /// `GroundRect`, or removes it when no ground plane is known yet.
    func update(groundRect: GroundRect?) {
      groundRectNode?.removeFromParentNode()
      groundRectNode = nil
      guard let groundRect, let scene = arView?.scene else { return }

      let corners = groundRect.worldCorners.map {
        SCNVector3(Float($0.x), Float($0.y), Float($0.z))
      }
      let node = Self.makeOutlineNode(corners: corners)
      scene.rootNode.addChildNode(node)
      groundRectNode = node
    }

    /// Builds a node showing 4 small spheres at the ground-rectangle
    /// corners plus connecting line segments, so the region being
    /// rectified is visible in the live AR view.
    private static func makeOutlineNode(corners: [SCNVector3]) -> SCNNode {
      let root = SCNNode()
      let sphereGeometry = SCNSphere(radius: 0.02)
      sphereGeometry.firstMaterial?.diffuse.contents = UIColor.systemYellow

      for corner in corners {
        let sphereNode = SCNNode(geometry: sphereGeometry.copy() as? SCNGeometry)
        sphereNode.position = corner
        root.addChildNode(sphereNode)
      }

      for i in 0..<corners.count {
        let start = corners[i]
        let end = corners[(i + 1) % corners.count]
        root.addChildNode(Self.makeLineNode(from: start, to: end))
      }

      return root
    }

    private static func makeLineNode(from start: SCNVector3, to end: SCNVector3) -> SCNNode {
      let vertices: [SCNVector3] = [start, end]
      let source = SCNGeometrySource(vertices: vertices)
      let indices: [Int32] = [0, 1]
      let element = SCNGeometryElement(indices: indices, primitiveType: .line)
      let geometry = SCNGeometry(sources: [source], elements: [element])
      geometry.firstMaterial?.diffuse.contents = UIColor.systemYellow
      return SCNNode(geometry: geometry)
    }

    // MARK: ARSCNViewDelegate

    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
      guard let planeAnchor = anchor as? ARPlaneAnchor else { return }
      node.addChildNode(Self.makePlaneNode(for: planeAnchor))
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
      guard let planeAnchor = anchor as? ARPlaneAnchor,
        let planeNode = node.childNodes.first,
        let plane = planeNode.geometry as? SCNPlane
      else {
        return
      }
      plane.width = CGFloat(planeAnchor.planeExtent.width)
      plane.height = CGFloat(planeAnchor.planeExtent.height)
      planeNode.simdPosition = planeAnchor.center
    }

    /// A translucent horizontal quad showing a detected plane.
    private static func makePlaneNode(for planeAnchor: ARPlaneAnchor) -> SCNNode {
      let plane = SCNPlane(
        width: CGFloat(planeAnchor.planeExtent.width),
        height: CGFloat(planeAnchor.planeExtent.height))
      plane.firstMaterial?.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.25)
      plane.firstMaterial?.isDoubleSided = true

      let planeNode = SCNNode(geometry: plane)
      planeNode.simdPosition = planeAnchor.center
      planeNode.eulerAngles.x = -.pi / 2
      return planeNode
    }
  }
}
