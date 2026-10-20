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
/// Total estimated byte size of a batch array.
fn batches_bytes(batches : Array[@types.DataBatch]) -> Int32 {
  let mut total = 0
  for b in batches {
    total += estimate_batch_bytes(b)
  }
  total
}

///|
fn mix32(h : Int32, v : Int32) -> Int32 {
  (h ^ v) * 16777619
}

///|
/// Partition id for row `r` of the key vectors: FNV-1a over the key
/// values (a NULL key component contributes a fixed marker), reduced
/// modulo `p`. Equal keys land in the same partition; distinct keys may
/// share one, which the per-partition join resolves.
fn key_partition(
  keys : Array[@types.ColumnVector],
  r : Int32,
  p : Int32,
) -> Int32 {
  // 2166136261 (the FNV offset basis) as a 32-bit two's complement
  let mut h = -2128831035
  for kv in keys {
    match kv.get(r) {
      @types.Null => h = mix32(h, -2128831035)
      @types.Boolean(v) => h = mix32(h, if v { 1 } else { 2 })
      @types.Int32(v) => h = mix32(h, v)
      @types.Int64(v) => h = mix32(h, v.to_int())
      @types.Float64(v) => h = mix32(h, v.to_int())
      @types.Str(s) =>
        for ch in s {
          h = mix32(h, ch.to_int())
        }
      @types.Date(v) => h = mix32(h, v)
    }
  }
  let m = h % p
  if m < 0 {
    m + p
  } else {
    m
  }
}

///|
/// Read one partition's spill runs back as batches (each spill file
/// deserializes to the batch sequence that was written into it).
fn read_partition(
  store : SpillStore,
  ids : Array[Int32],
) -> Array[@types.DataBatch] raise @types.SqlError {
  let out : Array[@types.DataBatch] = []
  for id in ids {
    let bs = @types.DataBatch::from_spill_bytes((store.read)(id))
    for b in bs {
      out.push(b)
    }
  }
  out
}

///|
/// Drop every spill file of both sides' partitions.
fn remove_join_partitions(
  store : SpillStore,
  wl : Array[RunWriter],
  wr : Array[RunWriter],
) -> Unit raise @types.SqlError {
  for w in wl {
    for id in w.ids {
      let _ = (store.remove)(id)
    }
  }
  for w in wr {
    for id in w.ids {
      let _ = (store.remove)(id)
    }
  }
}

///|
/// Route each row of `batch` into its key-hash partition writer.
fn partition_side(
  batch : @types.DataBatch,
  key_exprs : Array[PhysExpr],
  writers : Array[RunWriter],
) -> Unit raise @types.SqlError {
  let p = writers.length()
  let key_vecs : Array[@types.ColumnVector] = []
  for e in key_exprs {
    key_vecs.push(eval_vec(e, batch))
  }
  let idx : Array[Array[Int32]] = []
  for _ in 0..<p {
    idx.push([])
  }
  for r in 0..<batch.row_count() {
    idx[key_partition(key_vecs, r, p)].push(r)
  }
  for k in 0..<p {
    if idx[k].length() > 0 {
      writers[k].push(take_rows(batch, idx[k]))
    }
  }
}

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
  let mut p = bytes * 4 / budget + 1
  if p < 2 {
    p = 2
  }
  if p > JOIN_PARTITION_CAP {
    p = JOIN_PARTITION_CAP
  }
  p
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
) -> @types.DataBatch raise @types.SqlError {
  let out = join_partitions(acc, right, step, budget, store, stats, 0)
  concat_batches(out, step.out_dtypes)
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
) -> Array[@types.DataBatch] raise @types.SqlError {
  let p = partitions_for(batches_bytes(left) + batches_bytes(build), budget)
  let wl : Array[RunWriter] = []
  let wr : Array[RunWriter] = []
  for _ in 0..<p {
    wl.push({ store, budget, acc: [], acc_bytes: 0, ids: [], })
    wr.push({ store, budget, acc: [], acc_bytes: 0, ids: [], })
  }
  for batch in left {
    partition_side(batch, step.keys_l, wl)
  }
  for batch in build {
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
  errdefer remove_join_partitions(store, wl, wr)
  let out : Array[@types.DataBatch] = []
  for k in 0..<p {
    let left_p = read_partition(store, wl[k].ids)
    let build_p = read_partition(store, wr[k].ids)
    let lb = batches_bytes(left_p)
    let bb = batches_bytes(build_p)
    if lb <= budget && bb <= budget {
      out.push(join_step(left_p, build_p, step))
    } else if depth < JOIN_MAX_DEPTH {
      let sub = join_partitions(
        left_p,
        build_p,
        step,
        budget,
        store,
        stats,
        depth + 1,
      )
      for b in sub {
        out.push(b)
      }
    } else {
      raise @types.SqlError::Execute(
        "join partition \{k} exceeds the memory budget (left \{lb} + build \{bb} bytes > \{budget}) after \{depth} extra split level(s); one join-key value dominates a side, which no hash partitioning can split — raise the budget or filter that key",
      )
    }
  }
  remove_join_partitions(store, wl, wr)
  out
}
