namespace WindowsTweaker.Gui.Core.Protocol;

/// <summary>
/// The bridge protocol's fixed values. The backend half lives in
/// <c>src/WindowsTweaker/Private/Bridge/BridgeProtocol.ps1</c>; both sides must agree, and
/// the handshake is what proves they do.
/// </summary>
public static class ProtocolConstants
{
    /// <summary>Protocol version this client speaks.</summary>
    public const int Version = 1;

    /// <summary>Upper bound on one protocol line, matching the backend's frame bound.</summary>
    public const int MaxFrameBytes = 8 * 1024 * 1024;

    /// <summary>Default per-request deadline when the operation table gives none.</summary>
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(60);

    /// <summary>How long a clean shutdown waits for the backend to finish and exit.</summary>
    public static readonly TimeSpan ShutdownTimeout = TimeSpan.FromSeconds(20);

    /// <summary>Frame <c>type</c> values.</summary>
    public static class FrameType
    {
        public const string Hello = "hello";
        public const string Result = "result";
        public const string Error = "error";
        public const string Progress = "progress";
        public const string Notice = "notice";
    }

    /// <summary>Well-known error codes the backend can return.</summary>
    public static class ErrorCode
    {
        public const string UnknownOperation = "UnknownOperation";
        public const string RequiresElevation = "RequiresElevation";
        public const string Busy = "Busy";
        public const string Timeout = "Timeout";
        public const string Aborted = "Aborted";
        public const string InvalidRequest = "InvalidRequest";
        public const string FrameTooLarge = "FrameTooLarge";
        public const string MissingId = "MissingId";
        public const string InternalError = "InternalError";
        public const string PayloadTooLarge = "PayloadTooLarge";
        public const string FrameFailure = "FrameFailure";
    }
}
