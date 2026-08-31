-- chunk-merger-bin — retired.
--
-- This package existed to concatenate downloaded chunks into one file. That is now what the
-- download itself does: `cloud-storage` appends each part to the output as it arrives, so the
-- concatenation needs no second pass, no temp directory, and no handler.
--
-- It stays installed-but-quiet rather than being deleted, because removing a package somebody
-- has installed is not something a version bump should do to them. It contributes nothing, so
-- the chunk flow behaves as if it were not there — which is the correct behaviour now.
--
-- Nothing here is worth reviving: a handler is only needed when the merge is NOT a
-- concatenation (a format with a per-part header, one that needs padding stripped, one that
-- verifies a checksum). Write one of those against the same contribution point.

arbor.events.on("arbor:plugin_load", function(_ctx)
  arbor.log.info(
    "chunk-merger-bin is retired — chunk downloads concatenate as they go, so no handler "
    .. "is needed. You can uninstall this package."
  )
end)
