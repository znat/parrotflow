extension Walk {
    /// The format of `Walk.key`. Agent skills and memories store keys, so a
    /// change to what a key is built from (`key`, `path(below:role:)`,
    /// `plainRoles`, `shortHash`, or the name a node is keyed by) raises this,
    /// and the stored keys must be rebuilt.
    public static let keyVersion = 1
}
