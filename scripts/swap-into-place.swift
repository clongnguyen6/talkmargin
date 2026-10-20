// usage: swift scripts/swap-into-place.swift <staged.app> <dest.app>
// Puts the staged bundle at dest in one rename. When dest exists the two are swapped
// (renamex_np RENAME_SWAP): dest is never missing or half-written, and the previous bundle
// ends up at <staged.app> for the caller to delete. Both paths must be on the same volume.
import Darwin

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("usage: swap-into-place.swift <staged.app> <dest.app>\n", stderr)
    exit(2)
}
let staged = args[1], dest = args[2]
let swapping = access(dest, F_OK) == 0
// RENAME_SWAP = 0x2, RENAME_EXCL = 0x4 (sys/stdio.h).
let flags: UInt32 = swapping ? 0x2 : 0x4
guard renamex_np(staged, dest, flags) == 0 else {
    perror("renamex_np \(staged) -> \(dest)")
    exit(1)
}
print(swapping ? "swapped" : "placed")
