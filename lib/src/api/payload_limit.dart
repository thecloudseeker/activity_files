// SPDX-License-Identifier: BSD-3-Clause

/// The default of `maxPayloadBytes` on `ActivityFiles.import` and
/// `ActivityFiles.convert` when the caller leaves it out: sources over 64 MB
/// are read with a warning instead of refused. A value no caller can mean,
/// so an explicit 64 MB stays a hard cap.
const int softPayloadLimit = -1;
