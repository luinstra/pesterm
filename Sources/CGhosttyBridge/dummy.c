/*
 * dummy.c — token source so SwiftPM has something to compile for the CGhosttyBridge
 * C target (same shape as CITermBridge/dummy.c). The umbrella header
 * (include/GhosttyBridge.h) is consumed by Swift via `import CGhosttyBridge`; the
 * Objective-C parsing happens on the Swift-import side, not inside this C target.
 * Do NOT rename this to .m.
 */
