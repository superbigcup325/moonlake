// Grace hash join: when a join's inputs exceed the
// memory budget, both sides are partitioned by the hash of their join
// keys into per-partition spill runs (the same SpillStore the sort
// uses), and the existing in-memory join_step replays one partition at
// a time. Equal keys always land in the same partition, so a
// per-partition join is exactly the global join; NULL keys never match
// and may land anywhere. The engine still never touches the filesystem:
// partitions live in the injected SpillStore and are removed on every
// exit path.

///|
/// Cap on how many hash partitions one level may create.
const JOIN_PARTITION_CAP : Int32 = 256

///|
/// How many times an over-budget partition may be split again. Two
/// extra levels reach 256 x 256 partitions, which covers a very small
/// budget against a much larger input; what they cannot cover is one
/// join-key value holding most of a side, since equal keys must land in
/// the same partition at every level.
const JOIN_MAX_DEPTH : Int32 = 2

///|
/// Partition count for `bytes` under `budget`: proportional to the
/// input, at least two, at most JOIN_PARTITION_CAP.
fn partitions_for(bytes : Int32, budget : Int32) -> Int32 {
  partition_count(bytes, budget, JOIN_PARTITION_CAP)
}

///|
/// Grace hash join: partition both sides by join-key hash into spill
/// runs, then replay `join_step` per partition and concatenate.
///
/// A partition that still exceeds the budget after the first level is
/// partitioned again (up to JOIN_MAX_DEPTH) instead of failing: the
/// common cause is a small budget against a large input, where the
/// partition cap alone leaves partitions too big. Equal keys land in
/// the same partition at every level, so a multi-level split still
/// computes exactly the global join. Only one kind of skew survives it
/// — a single join-key value holding most of a side — and that is
/// reported with a message that says so, because no hash partitioning
/// can split a key.
fn grace_join(
  acc : Array[@types.DataBatch],
  right : Array[@types.DataBatch],
  step : JoinStep,
  budget : Int32,
  store : SpillStore,
  stats : Array[(String, Int64)],
  census~ : MemCensus? = None,
) -> Array[@types.DataBatch] raise @types.SqlError {
  // a partition's replay is a step's own batches, handed on as they are: the
  // caller collapses them once when the next step (or the eager path's own
  // bookkeeping) wants one batch a side (§65)
  join_partitions(acc, right, step, budget, store, stats, 0, census~)
}

///|
/// One partitioning level of the grace join, recursing on over-budget
/// partitions. `depth` counts the extra splits already applied.
fn join_partitions(
  left : Array[@types.DataBatch],
  build : Array[@types.DataBatch],
  step : JoinStep,
  budget : Int32,
  store : SpillStore,
  stats : Array[(String, Int64)],
  depth : Int32,
  census~ : MemCensus? = None,
) -> Array[@types.DataBatch] raise @types.SqlError {
  let p = partitions_for(batches_bytes(left) + batches_bytes(build), budget)
  let wl : Array[RunWriter] = []
  let wr : Array[RunWriter] = []
  for _ in 0..<p {
    wl.push(RunWriter::partitioned(store, budget))
    wr.push(RunWriter::partitioned(store, budget))
  }
  // Routed in chunks, not in the scan's own batches: `partition_side` pays one
  // gather per partition per input batch, which is 20x the gathers it needs when
  // the scan's 2048-row batches are grouped into budget/4 chunks (§92). The rows,
  // keys and partition numbers are untouched.
  let target = routing_chunk_bytes(budget)
  for batch in chunk_side(left, target) {
    partition_side(batch, step.keys_l, wl)
  }
  for batch in chunk_side(build, target) {
    partition_side(batch, step.keys_r, wr)
  }
  for k in 0..<p {
    wl[k].flush()
    wr[k].flush()
  }
  if stats.length() > 0 {
    if depth == 0 {
      stats.push(("spill partitions", p.to_int64()))
    } else {
      stats.push(("spill repartitions", p.to_int64()))
    }
  }
  errdefer remove_writer_sides(store, wl, wr)
  let out : Array[@types.DataBatch] = []
  for k in 0..<p {
    let left_p = read_partition(store, wl[k].ids)
    let build_p = read_partition(store, wr[k].ids)
    let lb = batches_bytes(left_p)
    let bb = batches_bytes(build_p)
    if lb <= budget && bb <= budget {
      for b in join_step(left_p, build_p, step) {
        out.push(b)
      }
    } else if depth < JOIN_MAX_DEPTH {
      let sub = join_partitions(
        left_p,
        build_p,
        step,
        budget,
        store,
        stats,
        depth + 1,
        census~,
      )
      for b in sub {
        out.push(b)
      }
    } else {
      raise @types.SqlError::Execute(
        "join partition \{k} exceeds the memory budget (left \{lb} + build \{bb} bytes > \{budget}) after \{depth} extra split level(s); one join-key value dominates a side, which no hash partitioning can split — raise the budget or filter that key",
      )
    }
    match census {
      Some(c) =>
        c.observe("spill partition replayed", [
          ("left partition (estimate)", resident_batches_bytes(left_p)),
          ("build partition (estimate)", resident_batches_bytes(build_p)),
          ("output accumulated (estimate)", resident_batches_bytes(out)),
        ])
      None => ()
    }
  }
  remove_writer_sides(store, wl, wr)
  out
}
