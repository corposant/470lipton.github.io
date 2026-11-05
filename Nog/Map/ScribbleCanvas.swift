import PencilKit
import SwiftUI

/// A transparent PencilKit layer for scribbling over the map, with finger or Pencil.
struct ScribbleCanvas: UIViewRepresentable {
    let drawing: PKDrawing
    let isActive: Bool
    let onChange: (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.drawing = drawing
        canvas.tool = PKInkingTool(.pen, color: UIColor(hex: 0xFF5FB0), width: 5)
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.onChange = onChange
        canvas.isUserInteractionEnabled = isActive
        if canvas.drawing != drawing && !context.coordinator.isDrawing {
            canvas.drawing = drawing
        }
        let picker = context.coordinator.toolPicker
        if isActive {
            picker.addObserver(canvas)
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        } else {
            picker.setVisible(false, forFirstResponder: canvas)
            canvas.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: (PKDrawing) -> Void
        let toolPicker = PKToolPicker()
        var isDrawing = false

        init(onChange: @escaping (PKDrawing) -> Void) {
            self.onChange = onChange
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { isDrawing = true }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { isDrawing = false }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let drawing = canvasView.drawing
            DispatchQueue.main.async { self.onChange(drawing) }
        }
    }
}
