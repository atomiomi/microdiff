import Testing

/// Parent of every UI suite. The tests share the main thread, the shared application object and
/// git processes, so they run one after another; running them in parallel is slower, not faster.
@Suite(.serialized)
enum UITests {}
