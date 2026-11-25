#if PERSONAL_APP_QA
// Reuse the existing locked, immutable in-memory QA store. No Security API,
// credential namespace or provider adapter is introduced for QA Google settings.
extension NativeMailQAServices: GoogleCalendarSecretStore {}
#endif
