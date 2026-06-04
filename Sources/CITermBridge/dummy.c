/*
 * dummy.c — token source so SwiftPM has something to compile for the CITermBridge
 * C target (V8). The generated umbrella header (include/iTermBridge.h) is consumed
 * by Swift via `import CITermBridge`; the Objective-C parsing happens on the
 * Swift-import side, not inside this C target. Do NOT rename this to .m.
 */
