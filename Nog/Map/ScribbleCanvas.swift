import Observation
import PencilKit
import SwiftUI

/// Lets the map's buttons drive the drawing layer: undo, redo, clear.
@MainActor
@Observable
final class ScribbleController {
    @ObservationIgnored weak var canvas: PKCanvasView?
    private(set) var canUndo = false
    private(set) var canRedo = false

    func undo() {
        canvas?.undoManager?.undo()
        refresh()
    }

    func redo() {
        canvas?.undoManager?.redo()
        refresh()
    }

    /// Clears every scribble (undoable).
    func clear() {
        guard let canvas else { return }
        let previous = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: canvas) { $0.drawing = previous }
        canvas.drawing = PKDrawing()
        refresh()
    }

    func refresh() {
        canUndo = canvas?.undoManager?.canUndo ?? false
        canRedo = canvas?.undoManager?.canRedo ?? false
    }
}

/// A transparent, screen-sized PencilKit layer for scribbling over the map.
///
/// While scribbling, the canvas is the source of truth: we never push a drawing back
/// into it mid-session (that would wipe its undo history and could loop). When not
/// scribbling, it simply shows the stored drawing through the map's pan/zoom.
struct ScribbleCanvas: UIViewRepresentable {
    let drawing: PKDrawing
    let isActive: Bool
    let controller: ScribbleController
    let onChange: (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, controller: controller) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.tool = PKInkingTool(.pen, color: UIColor(hex: 0xFF5FB0), width: 5)
        canvas.delegate = context.coordinator
        context.coordinator.apply(drawing, to: canvas)
        controller.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        canvas.isUserInteractionEnabled = isActive

        // Not scribbling: mirror the stored drawing (it moves with pan/zoom).
        if !isActive {
            coordinator.apply(drawing, to: canvas)
        }

        // Only touch the tool picker / first responder when the mode actually changes.
        guard isActive != coordinator.wasActive else { return }
        coordinator.wasActive = isActive
        let picker = coordinator.toolPicker
        if isActive {
            coordinator.apply(drawing, to: canvas)
            picker.addObserver(canvas)
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
            canvas.undoManager?.removeAllActions()
        } else {
            picker.setVisible(false, forFirstResponder: canvas)
            picker.removeObserver(canvas)
            canvas.resignFirstResponder()
        }
        controller.refresh()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: (PKDrawing) -> Void
        let controller: ScribbleController
        let toolPicker = PKToolPicker()
        var wasActive = false
        /// True while we set the drawing ourselves, so the delegate ignores that change.
        private var isApplying = false

        init(onChange: @escaping (PKDrawing) -> Void, controller: ScribbleController) {
            self.onChange = onChange
            self.controller = controller
        }

        func apply(_ drawing: PKDrawing, to canvas: PKCanvasView) {
            guard canvas.drawing != drawing else { return }
            isApplying = true
            canvas.drawing = drawing
            isApplying = false
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplying else { return }
            let drawing = canvasView.drawing
            DispatchQueue.main.async {
                self.onChange(drawing)
                MainActor.assumeIsolated { self.controller.refresh() }
            }
        }
    }
}
