// Web subpatch builds use the task 6880 mailbox contract without creating a
// thread: submit performs the CPU build inline, and the frame loop takes the
// result through the same one-shot receiver used by the native backend.
module subpatch_worker_web;

import subpatch_osd : CageSnapshot, OsdAccel, PreviewBuildResult;

/// Single-threaded backend for the WebAssembly editor build.
final class SubpatchWorker
{
    private bool resultReady_;
    private PreviewBuildResult result_;

    void submit(OsdAccel* accel, CageSnapshot* snap,
                ulong generation, ulong key)
    {
        assert(!resultReady_,
               "SubpatchWorker.submit with an untaken synchronous result");

        PreviewBuildResult res;
        res.generation = generation;
        res.key = key;
        try
        {
            accel.buildFromSnapshot(*snap, res);
        }
        catch (Throwable t)
        {
            res.ok = false;
            try
            {
                import log : logError;
                logError("subpatch", "preview build failed: " ~ t.msg);
            }
            catch (Exception)
            {
            }
        }

        result_ = res;
        resultReady_ = true;
    }

    bool tryTake(out PreviewBuildResult res)
    {
        if (!resultReady_) return false;
        res = result_;
        result_ = PreviewBuildResult.init;
        resultReady_ = false;
        return true;
    }

    @property bool busy() const pure nothrow @nogc
    {
        return false;
    }

    @property bool resultWaiting() const pure nothrow @nogc
    {
        return resultReady_;
    }

    @property bool supportsReceptionHold() const pure nothrow @nogc
    {
        return false;
    }

    bool waitIdle(long) const pure nothrow @nogc
    {
        return true;
    }

    void shutdown(long timeoutMs = 5_000) pure nothrow @nogc
    {
    }
}
