import CoreGraphics
import Foundation
import Observation

/// The wand's settle animation: each chip is a boid that steers toward its new spot,
/// keeps clear of chips it's about to hit (separation), and drifts with the other chips
/// of its project (cohesion and alignment), so groups swim together and flow around
/// each other instead of sliding through one another.
///
/// Boids only decide how chips travel, never where they land: the end positions are
/// worked out first, and the last part of the flight eases every chip exactly onto its
/// spot. Deterministic for the same steps. Not used with Reduce Motion or Low stimulation.
struct MapFlock {
    struct Boid {
        var position: CGPoint
        var velocity: CGVector = .zero
        let target: CGPoint
        let group: Int
        /// Half the chip's diagonal-ish size: how close another chip may come.
        let radius: CGFloat
    }

    private(set) var boids: [UUID: Boid]
    private let order: [UUID]
    private(set) var elapsed: TimeInterval = 0
    let duration: TimeInterval

    // Tuned for map points: chips cross a big map (1000+ points) in under a second.
    private static let maxSpeed: CGFloat = 3200
    private static let arriveTime: CGFloat = 0.16
    private static let steerGain: CGFloat = 9
    private static let separationStrength: CGFloat = 2600
    private static let cohesionStrength: CGFloat = 2.5
    private static let alignmentStrength: CGFloat = 1.5
    /// From this share of the flight on, chips are eased onto their spots.
    private static let landing: Double = 0.7

    /// Chips that don't move (no target, or already there) are left out.
    init(from start: [UUID: CGPoint], to targets: [UUID: CGPoint], groups: [UUID: Int] = [:],
         sizes: [UUID: CGSize] = [:], duration: TimeInterval = 0.9) {
        var boids: [UUID: Boid] = [:]
        for (id, target) in targets {
            guard let p = start[id], p != target else { continue }
            let s = MapLayout.size(id, in: sizes)
            boids[id] = Boid(position: p, target: target, group: groups[id] ?? -1,
                             radius: max(s.width, s.height) * 0.5)
        }
        self.boids = boids
        self.order = boids.keys.sorted { $0.uuidString < $1.uuidString }
        self.duration = duration
    }

    var isEmpty: Bool { boids.isEmpty }
    var isFinished: Bool { elapsed >= duration }

    /// Where each flying chip is now.
    var positions: [UUID: CGPoint] {
        let t = min(1, max(0, (elapsed / duration - Self.landing) / (1 - Self.landing)))
        let ease = CGFloat(t * t * (3 - 2 * t)) // smoothstep
        return boids.mapValues { b in
            CGPoint(x: b.position.x + (b.target.x - b.position.x) * ease,
                    y: b.position.y + (b.target.y - b.position.y) * ease)
        }
    }

    /// Advances the flight by `dt` seconds.
    mutating func step(_ dt: TimeInterval) {
        guard !isFinished, dt > 0 else { return }
        elapsed = min(duration, elapsed + dt)
        let h = CGFloat(min(dt, 1.0 / 20))
        // Flocking fades out as the flight goes on, so every chip ends up on its own spot.
        let flocking = CGFloat(max(0, 1 - elapsed / (duration * Self.landing)))

        // Group centres and average velocities, for cohesion and alignment.
        var sums: [Int: (p: CGPoint, v: CGVector, n: CGFloat)] = [:]
        for id in order {
            guard let b = boids[id], b.group >= 0 else { continue }
            var s = sums[b.group] ?? (p: CGPoint.zero, v: CGVector.zero, n: 0)
            s.p.x += b.position.x; s.p.y += b.position.y
            s.v.dx += b.velocity.dx; s.v.dy += b.velocity.dy
            s.n += 1
            sums[b.group] = s
        }

        var next = boids
        for id in order {
            guard var b = boids[id] else { continue }
            // Seek, slowing down on arrival.
            var desired = CGVector(dx: (b.target.x - b.position.x) / Self.arriveTime,
                                   dy: (b.target.y - b.position.y) / Self.arriveTime)
            desired = Self.limit(desired, Self.maxSpeed)
            var force = CGVector(dx: (desired.dx - b.velocity.dx) * Self.steerGain,
                                 dy: (desired.dy - b.velocity.dy) * Self.steerGain)

            if flocking > 0 {
                // Separation: push off chips that are too close.
                for otherID in order where otherID != id {
                    guard let o = boids[otherID] else { continue }
                    let dx = b.position.x - o.position.x, dy = b.position.y - o.position.y
                    let reach = b.radius + o.radius
                    guard abs(dx) < reach, abs(dy) < reach else { continue }
                    let d = max(1, (dx * dx + dy * dy).squareRoot())
                    guard d < reach else { continue }
                    let push = Self.separationStrength * (reach - d) / reach * flocking
                    force.dx += dx / d * push * 10
                    force.dy += dy / d * push * 10
                }
                // Cohesion and alignment with the rest of the group.
                if b.group >= 0, let s = sums[b.group], s.n > 1 {
                    let cx = s.p.x / s.n, cy = s.p.y / s.n
                    force.dx += (cx - b.position.x) * Self.cohesionStrength * flocking
                    force.dy += (cy - b.position.y) * Self.cohesionStrength * flocking
                    force.dx += (s.v.dx / s.n - b.velocity.dx) * Self.alignmentStrength * flocking
                    force.dy += (s.v.dy / s.n - b.velocity.dy) * Self.alignmentStrength * flocking
                }
            }

            b.velocity = Self.limit(CGVector(dx: b.velocity.dx + force.dx * h, dy: b.velocity.dy + force.dy * h),
                                    Self.maxSpeed)
            b.position = CGPoint(x: b.position.x + b.velocity.dx * h, y: b.position.y + b.velocity.dy * h)
            next[id] = b
        }
        boids = next
    }

    private static func limit(_ v: CGVector, _ maximum: CGFloat) -> CGVector {
        let m = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        guard m > maximum, m > 0 else { return v }
        return CGVector(dx: v.dx / m * maximum, dy: v.dy / m * maximum)
    }
}

/// Runs a `MapFlock` at screen rate and publishes where the chips are.
@MainActor
@Observable
final class MapFlight {
    private(set) var positions: [UUID: CGPoint]
    @ObservationIgnored private var flock: MapFlock
    @ObservationIgnored private var task: Task<Void, Never>?

    init(_ flock: MapFlock) {
        self.flock = flock
        self.positions = flock.positions
    }

    func start(onFinish: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                let now = clock.now
                let elapsed = now - last
                last = now
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                self.flock.step(seconds)
                self.positions = self.flock.positions
                if self.flock.isFinished { break }
            }
            guard !Task.isCancelled else { return }
            onFinish()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
