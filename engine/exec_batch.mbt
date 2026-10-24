// Batch primitives shared by every eager stage: gather rows by id, compact a
// filtered batch, take a row subset, concatenate batches, and the per-row
// string keys and counts the hash-based stages need. None of it knows about a
// plan; these are the moves each operator performs on a DataBatch.

///|
fn filter_batches(
  batches : Array[@types.DataBatch],
  pred : PhysExpr?,
) -> Array[@types.DataBatch] raise @types.SqlError {
  let out : Array[@types.DataBatch] = []
  for batch in batches {
    match pred {
      None => out.push(batch)
      Some(pe) => {
        let kept = compact(batch, eval_mask(pe, batch))
        if kept.row_count() > 0 {
          out.push(kept)
        }
      }
    }
  }
  out
}

///|
fn compact(
  batch : @types.DataBatch,
  mask : FixedArray[Bool],
) -> @types.DataBatch {
  let indices : Array[Int32] = []
  for r in 0..<batch.row_count() {
    if mask[r] {
      indices.push(r)
    }
  }
  take_rows(batch, indices)
}

///|
/// Build a new batch holding the selected input rows, preserving order.
/// Each column is one typed gather.
fn take_rows(
  batch : @types.DataBatch,
  indices : Array[Int32],
) -> @types.DataBatch {
  let columns : Array[@types.ColumnVector] = []
  for src in batch.columns() {
    columns.push(gather(src, indices))
  }
  @types.DataBatch::new(columns, indices.length())
}

///|
/// Gather rows by id into a fresh vector. A negative id writes an
/// invalid slot (LEFT join NULL extension). Typed per variant so the
/// gather writes plain arrays, no boxed Scalars.
fn gather(src : @types.ColumnVector, ids : Array[Int32]) -> @types.ColumnVector {
  let n = ids.length()
  match src {
    @types.I32(d, valid) => {
      let od : FixedArray[Int32] = FixedArray::make(n, 0)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.I32(od, ovalid)
    }
    @types.I64(d, valid) => {
      let od : FixedArray[Int64] = FixedArray::make(n, 0L)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.I64(od, ovalid)
    }
    @types.F64(d, valid) => {
      let od : FixedArray[Double] = FixedArray::make(n, 0.0)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.F64(od, ovalid)
    }
    @types.BoolV(d, valid) => {
      let od : FixedArray[Bool] = FixedArray::make(n, false)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.BoolV(od, ovalid)
    }
    @types.StrV(d, valid) => {
      let od : FixedArray[String] = FixedArray::make(n, "")
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.StrV(od, ovalid)
    }
    @types.DateV(d, valid) => {
      let od : FixedArray[Int32] = FixedArray::make(n, 0)
      let ovalid : FixedArray[Bool] = FixedArray::make(n, false)
      for w, i in ids {
        if i >= 0 && valid[i] {
          od[w] = d[i]
          ovalid[w] = true
        }
      }
      @types.DateV(od, ovalid)
    }
  }
}

///|
/// Columnar concatenation of batches sharing one layout. An empty input
/// yields a zero-row batch with the given layout (dtypes of the flat
/// row), so downstream expressions still see every column.
fn concat_batches(
  batches : Array[@types.DataBatch],
  dtypes : Array[@types.DataType],
) -> @types.DataBatch {
  if batches.length() == 1 {
    return batches[0]
  }
  if batches.length() == 0 {
    let columns : Array[@types.ColumnVector] = []
    for dt in dtypes {
      columns.push(@types.ColumnVector::make(dt, 0))
    }
    return @types.DataBatch::new(columns, 0)
  }
  let mut total = 0
  for b in batches {
    total += b.row_count()
  }
  let ncols = batches[0].columns().length()
  let columns : Array[@types.ColumnVector] = []
  for c in 0..<ncols {
    let dt = batches[0].columns()[c].dtype()
    let dst = @types.ColumnVector::make(dt, total)
    let mut w = 0
    for b in batches {
      // copy exactly the batch's live rows: builder-produced batches
      // carry capacity-sized vectors (4096) whose length exceeds
      // row_count — copying by vector length overruns the destination
      copy_vec_range(dst, w, b.columns()[c], b.row_count())
      w += b.row_count()
    }
    columns.push(dst)
  }
  @types.DataBatch::new(columns, total)
}

///|
/// Copy `n` rows of one vector into another at the given offset. Same
/// dtype by construction (concat batches share a layout); the fallback
/// mirrors ColumnVector::set's silent mismatch ignore.
fn copy_vec_range(
  dst : @types.ColumnVector,
  w : Int32,
  src : @types.ColumnVector,
  n : Int32,
) -> Unit {
  match (dst, src) {
    (@types.I32(dd, dv), @types.I32(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    (@types.I64(dd, dv), @types.I64(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    (@types.F64(dd, dv), @types.F64(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    (@types.BoolV(dd, dv), @types.BoolV(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    (@types.StrV(dd, dv), @types.StrV(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    (@types.DateV(dd, dv), @types.DateV(sd, sv)) =>
      for i in 0..<n {
        dd[w + i] = sd[i]
        dv[w + i] = sv[i]
      }
    _ => ()
  }
}

///|
/// NULL-safe multiset key of a whole row (set operations compare rows,
/// so unlike join keys a NULL here is a value that equals itself).
fn row_key(batch : @types.DataBatch, r : Int32) -> String {
  let kv : Array[@types.Scalar] = []
  for c in batch.columns() {
    kv.push(c.get(r))
  }
  canonical_key(kv)
}

///|
fn row_counts(batch : @types.DataBatch) -> Map[String, Int32] {
  let counts : Map[String, Int32] = Map([])
  for r in 0..<batch.row_count() {
    let k = row_key(batch, r)
    match counts.get(k) {
      Some(v) => counts[k] = v + 1
      None => counts[k] = 1
    }
  }
  counts
}
