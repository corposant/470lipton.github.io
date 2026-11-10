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

/// A transparent PencilKit layer for scribbling over the map.
///
/// The drawing is stored in map coordinates. Two modes:
/// - **Showing** (not scribbling): the canvas is drawn once at the current zoom, then
///   only moved and stretched as you pan and pinch (cheap Core Animation work). When a
///   pinch ends it's redrawn at the new zoom so strokes stay sharp.
/// - **Scribbling**: the canvas fills the screen and is the source of truth. We never
///   push a drawing back into it mid-session (that would wipe its undo history and
///   could loop). The map can't pan or zoom meanwhile, so screen ↔ map stays fixed.
struct ScribbleCanvas: UIViewRepresentable {
    /// The stored drawing, in map coordinates.
    let drawing: PKDrawing
    /// Changes whenever `drawing` does (cheaper than comparing drawings).
    let drawingVersion: Int
    /// Map → screen: a uniform scale plus a translation.
    let transform: CGAffineTransform
    /// While a pinch is under way the strokes are only stretched; they're redrawn sharp after.
    let isZooming: Bool
    let isActive: Bool
    let controller: ScribbleController
    /// Called with the new drawing in map coordinates.
    let onChange: (PKDrawing) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, controller: controller) }

    func makeUIView(context: Context) -> Host {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.tool = PKInkingTool(.pen, color: UIColor(hex: 0xFF5FB0), width: 5)
        canvas.delegate = context.coordinator
        canvas.isUserInteractionEnabled = false
        let host = Host(canvas: canvas)
        controller.canvas = canvas
        return host
    }

    func updateUIView(_ host: Host, context: Context) {
        let coordinator = context.coordinator
        let canvas = host.canvas
        coordinator.onChange = onChange
        canvas.isUserInteractionEnabled = isActive

        if isActive != coordinator.wasActive {
            coordinator.wasActive = isActive
            let picker = coordinator.toolPicker
            if isActive {
                coordinator.startScribbling(drawing, transform: transform, in: host)
                picker.addObserver(canvas)
                picker.setVisible(true, forFirstResponder: canvas)
                canvas.becomeFirstResponder()
                canvas.undoManager?.removeAllActions()
            } else {
                picker.setVisible(false, forFirstResponder: canvas)
                picker.removeObserver(canvas)
                // Stroke undos only make sense while scribbling; drop them so the map's
                // own Undo (moves, filing) never undoes a stroke instead.
                canvas.undoManager?.removeAllActions()
                canvas.resignFirstResponder()
                host.fillsBounds = false
                coordinator.bakedVersion = nil // redraw from the stored drawing
            }
            controller.refresh()
        }

        if !isActive {
            coordinator.show(drawing, version: drawingVersion, transform: transform,
                             sharpen: !isZooming, in: canvas)
        }
    }

    /// Holds the canvas. While scribbling, keeps it the same size as the map.
    final class Host: UIView {
        let canvas: PKCanvasView
        var fillsBounds = false {
            didSet { setNeedsLayout() }
        }

        init(canvas: PKCanvasView) {
            self.canvas = canvas
            super.init(frame: .zero)
            backgroundColor = .clear
            isOpaque = false
            addSubview(canvas)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard fillsBounds else { return }
            canvas.transform = .identity
            canvas.frame = bounds
        }

        // Not scribbling: let touches fall through to the map.
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard fillsBounds else { return nil }
            return super.hitTest(point, with: event)
        }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: (PKDrawing) -> Void
        let controller: ScribbleController
        let toolPicker = PKToolPicker()
        var wasActive = false
        /// True while we set the drawing ourselves, so the delegate ignores that change.
        private var isApplying = false

        /// Screen → map while scribbling.
        private var screenToMap = CGAffineTransform.identity

        // What the canvas currently shows while not scribbling.
        var bakedVersion: Int?
        /// The zoom the strokes were drawn at.
        private var bakedScale: CGFloat = 1
        /// The zoom that was asked for (differs from `bakedScale` only when capped).
        private var bakedFor: CGFloat = 1
        /// The drawing's area, in map coordinates.
        private var bakedBounds = CGRect.null

        /// Biggest canvas side we draw at full sharpness, in points.
        private static let maxSide: CGFloat = 4096

        init(onChange: @escaping (PKDrawing) -> Void, controller: ScribbleController) {
            self.onChange = onChange
            self.controller = controller
        }

        private func apply(_ drawing: PKDrawing, to canvas: PKCanvasView) {
            isApplying = true
            canvas.drawing = drawing
            isApplying = false
        }

        func startScribbling(_ drawing: PKDrawing, transform: CGAffineTransform, in host: Host) {
            host.fillsBounds = true
            host.layoutIfNeeded()
            host.canvas.isHidden = false
            host.canvas.transform = .identity
            host.canvas.frame = host.bounds
            host.canvas.contentSize = host.bounds.size
            screenToMap = transform.inverted()
            apply(drawing.transformed(using: transform), to: host.canvas)
        }

        /// Shows the stored drawing through the map's pan and zoom.
        func show(_ drawing: PKDrawing, version: Int, transform t: CGAffineTransform,
                  sharpen: Bool, in canvas: PKCanvasView) {
            let scale = max(0.01, t.a)
            if bakedVersion != version || (sharpen && abs(bakedFor - scale) > 0.0001) {
                bake(drawing, version: version, scale: scale, in: canvas)
            }
            guard !bakedBounds.isNull else {
                canvas.isHidden = true
                return
            }
            canvas.isHidden = false
            let stretch = scale / bakedScale
            canvas.transform = CGAffineTransform(scaleX: stretch, y: stretch)
            canvas.center = CGPoint(x: bakedBounds.midX, y: bakedBounds.midY).applying(t)
        }

        /// Draws the strokes once, at `scale`, onto a canvas just big enough to hold them.
        private func bake(_ drawing: PKDrawing, version: Int, scale: CGFloat, in canvas: PKCanvasView) {
            bakedVersion = version
            bakedFor = scale
            guard !drawing.strokes.isEmpty else {
                bakedBounds = .null
                apply(PKDrawing(), to: canvas)
                return
            }
            let bounds = drawing.bounds.insetBy(dx: -12, dy: -12)
            let side = max(bounds.width, bounds.height, 1)
            let s = min(scale, Self.maxSide / side)
            bakedScale = s
            bakedBounds = bounds
            let local = drawing.transformed(using: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
                .concatenating(CGAffineTransform(scaleX: s, y: s)))
            let size = CGSize(width: bounds.width * s, height: bounds.height * s)
            canvas.transform = .identity
            canvas.bounds = CGRect(origin: .zero, size: size)
            canvas.contentSize = size
            canvas.contentOffset = .zero
            apply(local, to: canvas)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplying, wasActive else { return }
            let drawing = canvasView.drawing.transformed(using: screenToMap)
            DispatchQueue.main.async {
                self.onChange(drawing)
                MainActor.assumeIsolated { self.controller.refresh() }
            }
        }
    }
}
