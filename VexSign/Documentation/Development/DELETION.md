# What "reset" and "clear" are allowed to do

Every destructive action in the app removes two things in two places — rows in the
Core Data store and files on disk — and each one used to do it in its own order with
its own error handling. This page is the contract those actions now share. The code
that implements it lives in `VexSign/App/iOS/Infrastructure/Persistence/Database/Storage.swift`
(`clearContext`, `clearSignedApps`, `clearImportedApps`, `clearCertificates`,
`clearSources`, `_libraryLeases`) and
`VexSign/App/iOS/Infrastructure/Signing/Transformation/TweakManager.swift`
(`resetLibrary`).

## The five rules

1. **Nothing is deleted while a job is using it.** A whole-library reset takes the same
   per-app leases `deleteApps` takes (`AppOperationRegistry.acquire(_:)`); the tweak
   library reset takes the workspace cleanup lease (`acquireCleanup()`). If any of the
   affected apps — or, for tweaks, any download, install or signing job — is busy, the
   action removes **nothing** and says why. It never deletes half a library.
2. **Memory and disk cannot disagree.** Lists are cleared only after the folder is
   really gone (`TweakManager.resetLibrary`). A failed delete leaves the lists intact
   so the user can see and retry what is still there.
3. **Rows are deleted by identity, not by surprise.** `clearContext` reads the object
   IDs first (`resultType = .managedObjectIDResultType`), runs the batch delete, then
   merges exactly those IDs back into the view context
   (`NSManagedObjectContext.mergeChanges(fromRemoteContextSave:into:)`). A batch delete
   alone never touches the object graph, which is why list counts used to drop to zero
   while the lists kept showing rows until a relaunch.
4. **A file without a row is garbage; a row without a file is a lie.** Where both must
   change, rows go first and the folder delete follows, and the folder delete is
   idempotent (`removeFileIfNeeded`). If it fails, the log names it and the leftovers
   are invisible files the next cleanup reclaims — never rows the UI shows but cannot
   open.
5. **No bare `try?` on the delete path.** Failures are logged with the error text and,
   where the user can act, shown as an error toast. The two remaining `try?` calls in
   this area are annotated with why they are best-effort.

## What each action removes

| Action | Rows | Disk | Guard |
| --- | --- | --- | --- |
| Reset tweak library (`TweakManager.resetLibrary`) | none (JSON, in memory) | `tweaks/` (the whole library) | `acquireCleanup()` |
| Reset certificates (`Storage.clearCertificates`) | `CertificatePair` | `certificates/`; `vexsign.selectedCert` preference | none — signing jobs are refused by the UI instead |
| Reset signed apps (`Storage.clearSignedApps(removeDirectory:)`) | `Signed` | `signed/` (when `removeDirectory`) | per-app leases |
| Reset imported apps (`Storage.clearImportedApps(removeDirectory:)`) | `Imported` | `unsigned/` (when `removeDirectory`) | per-app leases |
| Clear app history (same calls with `removeDirectory: false`) | `Signed` / `Imported` | untouched | per-app leases |
| Clear sources (`Storage.clearSources`) | `AltSource` | untouched | none — sources hold no files |

`removeDirectory: false` exists for the case where the user is resetting a list, not
the files: the rows go, the folder stays, and nothing is unlinked under an in-flight
operation.

## Reading is bounded too

The mirror image of deletion is "how much of a file will the app read". Those limits
are `FilePreviewLimit` in
`VexSign/App/iOS/Domain/Entities/FileWorkspaceEntry.swift` (8 MB text/plist, 12 MB
image, 1 KB hex, 64 KB strings) and are enforced in
`VexSign/App/iOS/Presentation/Shared/FilePreviewLoader.swift` and
`IPAFileLoader.isWithinReadLimit(_:limit:)` in
`VexSign/App/iOS/Infrastructure/Archives/IPA/IPAFileEntry.swift`. A file above a limit
is reported, not silently truncated: the notice says which limit applied.

## Changing this area

- Add the guard before adding the delete. A new destructive path that skips the lease
  reintroduces exactly the race these rules exist to prevent.
- If you add a row type to a library folder, add its cleanup to the matching `clear*`
  method in the same change, and take its leases with `_libraryLeases`.
- Touch neither the ordering (rows, then disk, then memory) nor the merge step without
  a test that fails when it is removed.
