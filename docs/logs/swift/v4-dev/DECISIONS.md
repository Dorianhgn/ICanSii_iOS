# Decisions Log - swift/v4-dev

Purpose: Lightweight ADRs. Why a path was chosen, what was rejected.

## Entry template
- Date:
- Decision:
- Context:
- Alternatives considered:
- Rationale:
- Consequences:

---

## 2026-04-15
- Date: 2026-04-15
- Decision: Keep spatial overlays in SwiftUI layer above SpatialMetalView rather than modifying SpatialRenderer.
- Context: Existing Metal renderer path is stable and substantial in size; user cannot run local iOS build from this Linux environment.
- Alternatives considered:
  - Extend SpatialRenderer to draw tracked markers in Metal -> rejected: elevated regression risk and longer debug loop.
  - Delay overlay work until full renderer refactor -> rejected: blocks immediate v4 demo visibility and QA.
- Rationale: SwiftUI overlay permits rapid iteration with low blast radius while preserving current renderer behavior.
- Consequences: Overlay precision depends on projection math and display transform parity; may require later consolidation into Metal for peak performance.

## 2026-04-15
- Date: 2026-04-15
- Decision: Introduce frame-coupled VisionFrameOutput for tracking ingestion.
- Context: Detection and depth fusion must be temporally aligned for stable 3D tracking.
- Alternatives considered:
  - Keep latest-frame/latest-detections buffering with lock -> rejected: temporal mismatch under async inference remains unresolved.
  - Add heuristic nearest-timestamp match in TrackingManager -> rejected: more complexity with no guarantee of exact source frame.
- Rationale: Publishing detections, prototypes, and source SpatialFrame together enforces deterministic fusion semantics.
- Consequences: VisionManager now owns a small pending-frame handoff mechanism; future refactors must preserve this coupling contract.

## 2026-04-15
- Date: 2026-04-15
- Decision: Serialize tracking updates on a dedicated queue.
- Context: Tracker state is mutable and not actor-isolated.
- Alternatives considered:
  - Rely on default scheduler behavior and locks around state -> rejected: harder to reason about and easy to regress.
  - Convert tracker stack to Swift actor immediately -> rejected: larger refactor than needed for this integration step.
- Rationale: A dedicated serial queue gives deterministic state transitions with minimal code churn.
- Consequences: Throughput depends on queue capacity; if future load increases, actorization or staged pipelining may be needed.

## 2026-04-20
- Date: 2026-04-20
- Decision: Apply drop-when-busy backpressure at TrackingManager ingestion boundary.
- Context: Vision output can outpace tracking compute during heavy mask assembly, causing queued frame buildup and stale processing.
- Alternatives considered:
  - Keep receive(on:) buffering and optimize only mask loop -> rejected: reduced compute cost alone cannot guarantee bounded queue depth under burst load.
  - Buffer latest frame and overwrite pending frame -> rejected: additional shared-state complexity without immediate need for latest-only replay semantics.
- Rationale: Single-inflight processing with frame drop gives strict upper bound on memory retained by queued frame payloads and removes latency accumulation from backlog.
- Consequences: Some frames are intentionally skipped under load; downstream tracking quality now trades temporal density for bounded latency and memory safety.
