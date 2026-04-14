# Difficulties Log — main

Purpose: Track blockers, root causes, and resolution paths.

## Entry template
- Date:
- Context:
- Symptom:
- Root cause (suspected/confirmed):
- Fix applied:
- Validation result:
- Open risk:

---

## 2026-03-25T08:18:21Z
- Context: Tri-plane scatter on iOS Metal (real-time debug overlays).
- Symptom: Shader build errors for `texture2d<atomic_uint>`, runtime abort at `setRenderPipelineState`.
- Root cause (confirmed):
  1. iOS toolchain forbids atomic texture channel usage as implemented.
  2. Debug overlay pipeline depth format mismatched with active MTKView render pass.
- Fix applied:
  1. Replaced atomic textures with linear `device atomic_uint*` buffers (row-major indexing).
  2. Created triplane debug pipeline with matching depth attachment format.
  3. Replaced CPU dispatch timing with async GPU timestamp logging.
- Validation result: `get_errors` reports no issues on all modified files.
- Open risk: Current timing covers full command-buffer interval; per-pass triplane timing may still be needed for profiling precision.
