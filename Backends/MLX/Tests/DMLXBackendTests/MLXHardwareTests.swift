import Testing

/// Serialize all suites that touch the process-wide MLX allocator and execution lease.
@Suite(.serialized)
struct MLXHardwareTests {}
