-- chunk-merger-bin — minimal chunk-handler for the cloud-storage plugin.
--
-- Contributes a single entry to `cloud-storage:cloud:chunk-handlers` and
-- exports the `merge` service that cloud-storage calls once the chunks are
-- downloaded. The actual byte-level concatenation is delegated to the host
-- helper `arbor.cloud.concat_files`, which streams the inputs in order and
-- writes a single output blob. Suitable for any artefact whose parts are
-- raw byte slices in their final order (split archives, tarball chunks,
-- pre-encoded video segments produced by the upload pipeline, …).
--
-- Not suitable for content-aware merges (zip catalog rewriting, video
-- container muxing, etc.) — those need a dedicated handler.

arbor.events.on("on_plugin_load", function(_ctx)
  -- Contribution payload follows the schema documented in the cloud-storage
  -- plugin doc: the cloud-storage sidebar reads `label`, `icon`, `service`
  -- to decide what to show in the chunk-handler picker and which service
  -- to invoke once the user confirms.
  arbor.ui.contribute("cloud-storage:cloud:chunk-handlers", {
    id = "binary-concat",
    payload = {
      label   = "Binary concatenation",
      icon    = "Combine",
      service = "chunk-merger-bin.merge",
    },
  })
  arbor.log.info("chunk-merger-bin ready")
end)

-- The merge service. Signature is contract-defined by cloud-storage; see
-- `plugins/cloud-storage/chunks.lua` (`arbor.service.call(service_name, …)`)
-- and the comment block at the top of the file for the full args table.
arbor.service.export("merge", function(args)
  args = args or {}
  local inputs    = args.inputs    or {}
  local output    = args.output    or ""
  local stream_id = args.stream_id or ""

  if #inputs == 0 then
    return { ok = false, error = "no input chunks" }
  end
  if output == "" then
    return { ok = false, error = "no output path" }
  end

  -- Cooperative cancellation: if the user has already cancelled while the
  -- download phase was wrapping up, bail out before doing any I/O. The
  -- shared cancel flag is keyed by stream_id and flipped by the
  -- OperationsOverlay card's Stop button (cancel_job → cloud_cancellations).
  if stream_id ~= "" then
    local cancelled = select(1, arbor.cloud.is_cancelled(stream_id))
    if cancelled then
      return { ok = false, error = "cancelled" }
    end
  end

  -- Streaming concat. `delete_inputs` is left false so cloud-storage's own
  -- post-merge cleanup (which also removes the tempdir itself) stays the
  -- single owner of that cleanup decision — keeps responsibilities clear
  -- if a future handler wants to keep the chunks around for diagnostics.
  local _, err = arbor.cloud.concat_files({
    inputs        = inputs,
    output        = output,
    delete_inputs = false,
  })
  if err then
    return { ok = false, error = "concat failed: " .. tostring(err) }
  end
  return { ok = true }
end)
