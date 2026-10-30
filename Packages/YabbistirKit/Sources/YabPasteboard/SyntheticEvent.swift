/// Marks keystrokes yabbistir posts itself (⌘V, ⌃V, ⌘C) in `eventSourceUserData`, so its own
/// paste detection can tell them from the user's.
public enum SyntheticEvent {
    /// "yabb"
    public static let marker: Int64 = 0x7961_6262
}
