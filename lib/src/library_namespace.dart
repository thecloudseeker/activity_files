// SPDX-License-Identifier: BSD-3-Clause

/// Namespace of the elements this library writes into a format's extension
/// areas. An identifier, not a location: it is never fetched.
const String libraryNamespace =
    'https://schemas.eikedreier.com/activity_files/v1';

/// The library namespace before [libraryNamespace] replaced it; still read.
const String legacyLibraryNamespace =
    'https://schemas.activityfiles.dev/extensions';

/// The element in a TCX lap's extensions that lists, space-separated, the
/// required lap elements the encoder filled with the schema's neutral value
/// because the activity had none, so the parser reads them back as absent.
const String tcxDefaultedFieldsElement = 'DefaultedFields';
