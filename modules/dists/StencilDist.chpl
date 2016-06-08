/*
 * Copyright 2004-2016 Cray Inc.
 * Other additional copyright holders may be indicated within.
 * 
 * The entirety of this work is licensed under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * 
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//
// The Stencil distribution is defined with six classes:
//
//   Stencil       : distribution class
//   StencilDom    : domain class
//   StencilArr    : array class
//   LocStencil    : local distribution class (per-locale instances)
//   LocStencilDom : local domain class (per-locale instances)
//   LocStencilArr : local array class (per-locale instances)
//
// When a distribution, domain, or array class instance is created, a
// corresponding local class instance is created on each locale that is
// mapped to by the distribution.
//

//
// TO DO List
//
// 1. refactor pid fields from distribution, domain, and array classes
//

use BlockDist;
use DSIUtil;
use ChapelUtil;
use CommDiagnostics;


//
// These flags are used to output debug information and run extra
// checks when using Stencil.  Should these be promoted so that they can
// be used across all distributions?  This can be done by turning them
// into compiler flags or adding config parameters to the internal
// modules, perhaps called debugDists and checkDists.
//
config param debugStencilDist = false;
config param debugStencilDistBulkTransfer = false;

// Re-uses these flags from BlockDist:
//   - disableAliasedBulkTransfer
//   - sanityCheckDistribution
//   - testFastFollowerOptimization

//
// This flag is used to disable lazy initialization of the RAD cache.
//
config param disableStencilLazyRAD = defaultDisableLazyRADOpt;

//
// Stencil Distribution Class
//
//   The fields dataParTasksPerLocale, dataParIgnoreRunningTasks, and
//   dataParMinGranularity can be changed, but changes are
//   not reflected in privatized copies of this distribution.  Perhaps
//   this is a feature, not a bug?!
//
// rank : generic rank that must match the rank of domains and arrays
//        declared over this distribution
//
// idxType: generic index type that must match the index type of
//          domains and arrays declared over this distribution
//
// boundingBox: a non-distributed domain defining a bounding box used
//              to partition the space of all indices across the array
//              of target locales; the indices inside the bounding box
//              are partitioned "evenly" across the locales and
//              indices outside the bounding box are mapped to the
//              same locale as the nearest index inside the bounding
//              box
//
// targetLocDom: a non-distributed domain over which the array of
//               target locales and the array of local distribution
//               classes are defined
//
// targetLocales: a non-distributed array containing the target
//                locales to which this distribution partitions indices
//                and data
//
// locDist: a non-distributed array of local distribution classes
//
// dataParTasksPerLocale: an integer that specifies the number of tasks to
//                        use on each locale when iterating in parallel over
//                        a Stencil-distributed domain or array
//
// dataParIgnoreRunningTasks: a boolean what dictates whether the number of
//                            task use on each locale should be limited
//                            by the available parallelism
//
// dataParMinGranularity: the minimum required number of elements per
//                        task created
//

/*

  .. warning::

    As of 1.13 the Stencil distribution is neither heavily documented nor tested.
    We aim to improve this situation in the future.

  For information on how indices are partitioned, see the Block distribution
  documentation. The Stencil distribution re-uses that same logic.

  The ``Stencil`` class constructor is defined as follows:

    .. code-block:: chapel

      proc Stencil(
        boundingBox: domain,
        targetLocales: [] locale  = Locales,
        dataParTasksPerLocale     = // value of  dataParTasksPerLocale      config const,
        dataParIgnoreRunningTasks = // value of  dataParIgnoreRunningTasks  config const,
        dataParMinGranularity     = // value of  dataParMinGranularity      config const,
        param rank                = boundingBox.rank,
        type  idxType             = boundingBox.idxType,
        fluff: rank*idxType       = makeZero(rank),
        periodic: bool            = false)

  The ``fluff`` argument indicates the requested space for ghost cells. ``fluff``
  will be used to expand the ``boundingBox`` in each direction to increase the
  index space that can be accessed. The default for each component of the tuple
  is zero.

  The ``periodic`` argument indicates whether or not the stencil should treat
  the array as a discrete chunk in a larger system. When enabled, the ghost cells
  outside of ``boundingBox`` will contain values as if the array data were
  replicated on all sides of the array. The ``periodic`` feature is disabled by
  default.

  ** Updating the Ghost Cache **

  Once you have completed a series of writes to the array, you will need to
  call the special ``updateFluff`` function to update the ghost cache for each
  locale:

  .. code-block:: chapel

    use StencilDist;

    const Dom = {1..10, 1..10};
    const Space = Dom dmapped Stencil(Dom, fluff=(1,1));
    var A : [Space] int;

    [(i,j) in Space] A[i,j] = i*10 + j;

    A.updateFluff();

  After updating, any read from the array should be up-to-date. The ``updateFluff``
  function does not currently accept any arguments.

  ** Reading and Writing to Array Elements **

  The Stencil distribution uses ghost cells as cached read-only values from other
  locales. When reading from a Stencil-distributed array, the distribution will
  attempt to read from the local ghost cache first. If the index is not owned by
  the ghost space, then a remote read from the owner locale occurs.

  Any write to array data will be applied to the 'actual', non-ghost-cache data.
  If you do write to the ghost cache, that value will be overwritten during the
  next ``updateFluff`` call.

  ** Modifying Exterior Ghost Cells **

  Updating the outermost ghost cells can be useful when working with a periodic
  stencil-distributed array. If your array contains position information, you may
  want to modify the ghost cells to 'wrap' around the physical space correctly.

  You can currently do this with the ``boundaries()`` iterator on a
  stencil-distributed array. This iterator yields a tuple where the first component
  is the ghost cell element to be modified, and the second component is a tuple
  indicating the side on which this ghost cell lives. This direction tuple will
  contain values in the range "-1..1".

  See miniMD for an example of how to use this iterator.

  .. warning::

    There is a known issue with this iterator where the program will fail to
    compile if the array element is not an array or a class.

*/
class Stencil : BaseDist {
  param rank: int;
  type idxType = int;
  var boundingBox: domain(rank, idxType);
  var targetLocDom: domain(rank);
  var targetLocales: [targetLocDom] locale;
  var locDist: [targetLocDom] LocStencil(rank, idxType);
  var dataParTasksPerLocale: int;
  var dataParIgnoreRunningTasks: bool;
  var dataParMinGranularity: int;
  var pid: int = -1; // privatized object id (this should be factored out)
  var fluff: rank*idxType;
  var periodic: bool = false;
}

//
// Local Stencil Distribution Class
//
// rank : generic rank that matches Stencil.rank
// idxType: generic index type that matches Stencil.idxType
// myChunk: a non-distributed domain that defines this locale's indices
//
class LocStencil {
  param rank: int;
  type idxType;
  const myChunk: domain(rank, idxType);
}

//
// Stencil Domain Class
//
// rank:      generic domain rank
// idxType:   generic domain index type
// stridable: generic domain stridable parameter
// dist:      reference to distribution class
// locDoms:   a non-distributed array of local domain classes
// whole:     a non-distributed domain that defines the domain's indices
//
class StencilDom: BaseRectangularDom {
  param rank: int;
  type idxType;
  param stridable: bool;
  const dist: Stencil(rank, idxType);
  var locDoms: [dist.targetLocDom] LocStencilDom(rank, idxType, stridable);
  var whole: domain(rank=rank, idxType=idxType, stridable=stridable);
  var pid: int = -1; // privatized object id (this should be factored out)
  var fluff: rank*idxType;
  var periodic: bool = false;
  var wholeFluff : domain(rank=rank, idxType=idxType, stridable=stridable);
}

//
// Local Stencil Domain Class
//
// rank: generic domain rank
// idxType: generic domain index type
// stridable: generic domain stridable parameter
// myBlock: a non-distributed domain that defines the local indices
//
class LocStencilDom {
  param rank: int;
  type idxType;
  param stridable: bool;
  var myBlock, myFluff: domain(rank, idxType, stridable);
  var NeighDom: domain(rank);
  var Dest, Src: [NeighDom] domain(rank, idxType, stridable);
  var Neighs: [NeighDom] rank*idxType;
}

//
// Stencil Array Class
//
// eltType: generic array element type
// rank: generic array rank
// idxType: generic array index type
// stridable: generic array stridable parameter
// dom: reference to domain class
// locArr: a non-distributed array of local array classes
// myLocArr: optimized reference to here's local array class (or nil)
//
class StencilArr: BaseArr {
  type eltType;
  param rank: int;
  type idxType;
  param stridable: bool;
  var doRADOpt: bool = defaultDoRADOpt;
  var dom: StencilDom(rank, idxType, stridable);
  var locArr: [dom.dist.targetLocDom] LocStencilArr(eltType, rank, idxType, stridable);
  var myLocArr: LocStencilArr(eltType, rank, idxType, stridable);
  var pid: int = -1; // privatized object id (this should be factored out)
  const SENTINEL = max(rank*idxType);
}

//
// Local Stencil Array Class
//
// eltType: generic array element type
// rank: generic array rank
// idxType: generic array index type
// stridable: generic array stridable parameter
// locDom: reference to local domain class
// myElems: a non-distributed array of local elements
//
class LocStencilArr {
  type eltType;
  param rank: int;
  type idxType;
  param stridable: bool;
  const locDom: LocStencilDom(rank, idxType, stridable);
  var locRAD: LocRADCache(eltType, rank, idxType); // non-nil if doRADOpt=true
  var myElems: [locDom.myFluff] eltType;
  var locRADLock: atomicflag; // This will only be accessed locally
                              // force the use of processor atomics

  // These function will always be called on this.locale, and so we do
  // not have an on statement around the while loop below (to avoid
  // the repeated on's from calling testAndSet()).
  inline proc lockLocRAD() {
    while locRADLock.testAndSet() do chpl_task_yield();
  }

  inline proc unlockLocRAD() {
    locRADLock.clear();
  }
}

private proc makeZero(param rank : int) {
  var ret : rank*int;
  return ret;
}
//
// Stencil constructor for clients of the Stencil distribution
//
proc Stencil.Stencil(boundingBox: domain,
                targetLocales: [] locale = Locales,
                dataParTasksPerLocale=getDataParTasksPerLocale(),
                dataParIgnoreRunningTasks=getDataParIgnoreRunningTasks(),
                dataParMinGranularity=getDataParMinGranularity(),
                param rank = boundingBox.rank,
                type idxType = boundingBox.idxType,
                fluff: rank*idxType = makeZero(rank), 
                periodic: bool = false) {
  if rank != boundingBox.rank then
    compilerError("specified Stencil rank != rank of specified bounding box");
  if idxType != boundingBox.idxType then
    compilerError("specified Stencil index type != index type of specified bounding box");

  this.boundingBox = boundingBox : domain(rank, idxType, stridable=false);
  this.fluff = fluff;

  // can't have periodic if there's no fluff
  this.periodic = periodic && !zeroTuple(fluff);

  setupTargetLocalesArray(targetLocDom, this.targetLocales, targetLocales);

  const boundingBoxDims = this.boundingBox.dims();
  const targetLocDomDims = targetLocDom.dims();
  coforall locid in targetLocDom do
    on this.targetLocales(locid) do
      locDist(locid) =  new LocStencil(rank, idxType, locid, boundingBoxDims,
                                     targetLocDomDims);

  // NOTE: When these knobs stop using the global defaults, we will need
  // to add checks to make sure dataParTasksPerLocale<0 and
  // dataParMinGranularity<0
  this.dataParTasksPerLocale = if dataParTasksPerLocale==0
                               then here.maxTaskPar
                               else dataParTasksPerLocale;
  this.dataParIgnoreRunningTasks = dataParIgnoreRunningTasks;
  this.dataParMinGranularity = dataParMinGranularity;

  if debugStencilDist {
    writeln("Creating new Stencil distribution:");
    dsiDisplayRepresentation();
  }
}

proc Stencil.dsiAssign(other: this.type) {
  coforall locid in targetLocDom do
    on targetLocales(locid) do
      delete locDist(locid);
  boundingBox = other.boundingBox;
  targetLocDom = other.targetLocDom;
  targetLocales = other.targetLocales;
  dataParTasksPerLocale = other.dataParTasksPerLocale;
  dataParIgnoreRunningTasks = other.dataParIgnoreRunningTasks;
  dataParMinGranularity = other.dataParMinGranularity;
  const boundingBoxDims = boundingBox.dims();
  const targetLocDomDims = targetLocDom.dims();

  coforall locid in targetLocDom do
    on targetLocales(locid) do
      locDist(locid) = new LocStencil(rank, idxType, locid, boundingBoxDims,
                                    targetLocDomDims);
}

//
// Stencil distributions are equivalent if they share the same bounding
// box and target locale set.
//
proc Stencil.dsiEqualDMaps(that: Stencil(?)) {
  return (this.boundingBox == that.boundingBox &&
          this.targetLocales.equals(that.targetLocales) &&
          this.fluff == that.fluff &&
          this.periodic == that.periodic);
}


proc Stencil.dsiEqualDMaps(that) param {
  return false;
}



proc Stencil.dsiClone() {
  return new Stencil(boundingBox, targetLocales,
                   dataParTasksPerLocale, dataParIgnoreRunningTasks,
                   dataParMinGranularity, fluff=fluff, periodic=periodic);
}

proc Stencil.dsiDestroyDistClass() {
  coforall ld in locDist do {
    on ld do
      delete ld;
  }
}

proc Stencil.dsiDisplayRepresentation() {
  writeln("boundingBox = ", boundingBox);
  writeln("targetLocDom = ", targetLocDom);
  writeln("targetLocales = ", for tl in targetLocales do tl.id);
  writeln("dataParTasksPerLocale = ", dataParTasksPerLocale);
  writeln("dataParIgnoreRunningTasks = ", dataParIgnoreRunningTasks);
  writeln("dataParMinGranularity = ", dataParMinGranularity);
  for tli in targetLocDom do
    writeln("locDist[", tli, "].myChunk = ", locDist[tli].myChunk);
}

proc Stencil.dsiNewRectangularDom(param rank: int, type idxType,
                              param stridable: bool) {
  if idxType != this.idxType then
    compilerError("Stencil domain index type does not match distribution's");
  if rank != this.rank then
    compilerError("Stencil domain rank does not match distribution's");

  var dom = new StencilDom(rank=rank, idxType=idxType, dist=this, stridable=stridable, fluff=fluff, periodic=periodic);
  dom.setup();
  if debugStencilDist {
    writeln("Creating new Stencil domain:");
    dom.dsiDisplayRepresentation();
  }
  return dom;
}

//
// output distribution
//
proc Stencil.writeThis(x) {
  x.writeln("Stencil");
  x.writeln("-------");
  x.writeln("distributes: ", boundingBox);
  x.writeln("across locales: ", targetLocales);
  x.writeln("indexed via: ", targetLocDom);
  x.writeln("resulting in: ");
  for locid in targetLocDom do
    x.writeln("  [", locid, "] locale ", locDist(locid).locale.id, " owns chunk: ", locDist(locid).myChunk);
}

proc Stencil.dsiIndexToLocale(ind: idxType) where rank == 1 {
  return targetLocales(targetLocsIdx(ind));
}

proc Stencil.dsiIndexToLocale(ind: rank*idxType) where rank > 1 {
  return targetLocales(targetLocsIdx(ind));
}

//
// compute what chunk of inds is owned by a given locale -- assumes
// it's being called on the locale in question
//
proc Stencil.getChunk(inds, locid) {
  // use domain slicing to get the intersection between what the
  // locale owns and the domain's index set
  //
  // TODO: Should this be able to be written as myChunk[inds] ???
  //
  // TODO: Does using David's detupling trick work here?
  //
  const chunk = locDist(locid).myChunk((...inds.getIndices()));
  if sanityCheckDistribution then
    if chunk.numIndices > 0 {
      if targetLocsIdx(chunk.low) != locid then
        writeln("[", here.id, "] ", chunk.low, " is in my chunk but maps to ",
                targetLocsIdx(chunk.low));
      if targetLocsIdx(chunk.high) != locid then
        writeln("[", here.id, "] ", chunk.high, " is in my chunk but maps to ",
                targetLocsIdx(chunk.high));
    }
  return chunk;
}

//
// get the index into the targetLocales array for a given distributed index
//
proc Stencil.targetLocsIdx(ind: idxType) where rank == 1 {
  return targetLocsIdx((ind,));
}

proc Stencil.targetLocsIdx(ind: rank*idxType) {
  var result: rank*int;
  for param i in 1..rank do
    result(i) = max(0, min((targetLocDom.dim(i).length-1):int,
                           (((ind(i) - boundingBox.dim(i).low) *
                             targetLocDom.dim(i).length:idxType) /
                            boundingBox.dim(i).length):int));
  return if rank == 1 then result(1) else result;
}

proc Stencil.dsiCreateReindexDist(newSpace, oldSpace) {
  proc anyStridable(space, param i=1) param
    return if i == space.size then space(i).stridable
           else space(i).stridable || anyStridable(space, i+1);

  // Should this error be in ChapelArray or not an error at all?
  if newSpace(1).idxType != oldSpace(1).idxType then
    compilerError("index type of reindex domain must match that of original domain");
  if anyStridable(newSpace) || anyStridable(oldSpace) then
    compilerWarning("reindexing stridable Stencil arrays is not yet fully supported");

  /* To shift the bounding box, we must perform the following operation for
   *  each dimension:
   *
   *   bbox(r).low - (oldSpace(r).low - newSpace(r).low)
   *   bbox(r).high - (oldSpace(r).low - newSpace(r).low)
   *
   * The following is guaranteed on entry:
   *
   *   oldSpace(r).low-newSpace(r).low = oldSpace(r).high-newSpace(r).high
   *
   * We need to be able to do this without going out of range of the index
   *  type.  The approach we take is to check if there is a way to perform
   *  the calculation without having any of the intermediate results go out
   *  of range.
   *
   *    newBbLow = bbLow - (oldLow - newLow)
   *    newBbLow = bbLow - oldLow + newLow
   *
   * Can be performed as:
   *
   *    t = oldLow-newLow;
   *    newBbLow = bbLow-t;
   * or
   *    t = bbLow-oldLow;
   *    newBbLow = t+newLow;
   * or
   *    t = bbLow+newLow;
   *    newBbLow = t-oldLow;
   *
   */
  proc adjustBound(bbound, oldBound, newBound) {
    var t: bbound.type;
    if safeSub(oldBound, newBound) {
      t = oldBound-newBound;
      if safeSub(bbound, t) {
        return (bbound-t, true);
      }
    }
    if safeSub(bbound, oldBound) {
      t = bbound-oldBound;
      if safeAdd(t, newBound) {
        return (t+newBound, true);
      }
    }
    if safeAdd(bbound, newBound) {
      t = bbound+newBound;
      if safeSub(t, oldBound) {
        return(t-oldBound, true);
      }
    }
    return (bbound, false);
  }

  var myNewBbox = boundingBox.dims();
  for param r in 1..rank {
    var oldLow = oldSpace(r).low;
    var newLow = newSpace(r).low;
    var oldHigh = oldSpace(r).high;
    var newHigh = newSpace(r).high;
    var valid: bool;
    if oldLow != newLow {
      (myNewBbox(r)._low,valid) = adjustBound(myNewBbox(r).low,oldLow,newLow);
      if !valid then // try with high
        (myNewBbox(r)._low,valid) = adjustBound(myNewBbox(r).low,oldHigh,newHigh);
      if !valid then
        halt("invalid reindex for Stencil: distribution bounding box (low) out of range in dimension ", r);

      (myNewBbox(r)._high,valid) = adjustBound(myNewBbox(r).high,oldHigh,newHigh);
      if !valid then
        (myNewBbox(r)._high,valid) = adjustBound(myNewBbox(r).high,oldLow,newLow);
      if !valid then // try with low
        halt("invalid reindex for Stencil: distribution bounding box (high) out of range in dimension ", r);
    }
  }
  var d = {(...myNewBbox)};
  var newDist = new Stencil(d, targetLocales, 
                          dataParTasksPerLocale, dataParIgnoreRunningTasks,
                          dataParMinGranularity, fluff=fluff, periodic=periodic);
  return newDist;
}


proc LocStencil.LocStencil(param rank: int,
                      type idxType, 
                      locid, // the locale index from the target domain
                      boundingBox: rank*range(idxType),
                      targetLocBox: rank*range) {
  if rank == 1 {
    const lo = boundingBox(1).low;
    const hi = boundingBox(1).high;
    const numelems = hi - lo + 1;
    const numlocs = targetLocBox(1).length;
    const (blo, bhi) = _computeBlock(numelems, numlocs, locid,
                                     max(idxType), min(idxType), lo);
    myChunk = {blo..bhi};
  } else {
    var inds: rank*range(idxType);
    for param i in 1..rank {
      const lo = boundingBox(i).low;
      const hi = boundingBox(i).high;
      const numelems = hi - lo + 1;
      const numlocs = targetLocBox(i).length;
      const (blo, bhi) = _computeBlock(numelems, numlocs, locid(i),
                                       max(idxType), min(idxType), lo);
      inds(i) = blo..bhi;
    }
    myChunk = {(...inds)};
  }
}

proc StencilDom.dsiMyDist() return dist;

proc StencilDom.dsiDisplayRepresentation() {
  writeln("whole = ", whole);
  for tli in dist.targetLocDom do
    writeln("locDoms[", tli, "].myBlock = ", locDoms[tli].myBlock);
}

proc StencilDom.dsiDims() return whole.dims();

proc StencilDom.dsiDim(d: int) return whole.dim(d);

// stopgap to avoid accessing locDoms field (and returning an array)
proc StencilDom.getLocDom(localeIdx) return locDoms(localeIdx);


//
// Given a tuple of scalars of type t or range(t) match the shape but
// using types rangeType and scalarType e.g. the call:
// _matchArgsShape(range(int(32)), int(32), (1:int(64), 1:int(64)..5, 1:int(64)..5))
// returns the type: (int(32), range(int(32)), range(int(32)))
//
proc _matchArgsShape(type rangeType, type scalarType, args) type {
  proc helper(param i: int) type {
    if i == args.size {
      if isCollapsedDimension(args(i)) then
        return (scalarType,);
      else
        return (rangeType,);
    } else {
      if isCollapsedDimension(args(i)) then
        return (scalarType, (... helper(i+1)));
      else
        return (rangeType, (... helper(i+1)));
    }
  }
  return helper(1);
}


proc Stencil.dsiCreateRankChangeDist(param newRank: int, args) {
  var collapsedDimLocs: rank*idxType;

  for param i in 1..rank {
    if isCollapsedDimension(args(i)) {
      collapsedDimLocs(i) = args(i);
    } else {
      collapsedDimLocs(i) = 0;
    }
  }
  const collapsedLocInd = targetLocsIdx(collapsedDimLocs);
  var collapsedBbox: _matchArgsShape(range(idxType=idxType), idxType, args);
  var collapsedLocs: _matchArgsShape(range(idxType=int), int, args);

  for param i in 1..rank {
    if isCollapsedDimension(args(i)) {
      // set indices that are out of bounds to the bounding box low or high.
      collapsedBbox(i) = if args(i) < boundingBox.dim(i).low then boundingBox.dim(i).low else if args(i) > boundingBox.dim(i).high then boundingBox.dim(i).high else args(i);
      collapsedLocs(i) = collapsedLocInd(i);
    } else {
      collapsedBbox(i) = boundingBox.dim(i);
      collapsedLocs(i) = targetLocDom.dim(i);
    }
  }

  const newBbox = boundingBox[(...collapsedBbox)];
  const newTargetLocales = targetLocales((...collapsedLocs));
  return new Stencil(newBbox, newTargetLocales,
                   dataParTasksPerLocale, dataParIgnoreRunningTasks,
                   dataParMinGranularity, fluff=fluff, periodic=periodic);
}

iter StencilDom.these() {
  for i in whole do
    yield i;
}

iter StencilDom.these(param tag: iterKind) where tag == iterKind.leader {
  const maxTasks = dist.dataParTasksPerLocale;
  const ignoreRunning = dist.dataParIgnoreRunningTasks;
  const minSize = dist.dataParMinGranularity;
  const wholeLow = whole.low;

  // If this is the only task running on this locale, we don't want to
  // count it when we try to determine how many tasks to use.  Here we
  // check if we are the only one running, and if so, use
  // ignoreRunning=true for this locale only.  Obviously there's a bit
  // of a race condition if some other task starts after we check, but
  // in that case there is no correct answer anyways.
  //
  // Note that this code assumes that any locale will only be in the
  // targetLocales array once.  If this is not the case, then the
  // tasks on this locale will *all* ignoreRunning, which may have
  // performance implications.
  const hereId = here.id;
  const hereIgnoreRunning = if here.runningTasks() == 1 then true
                            else ignoreRunning;
  coforall locDom in locDoms do on locDom {
    const myIgnoreRunning = if here.id == hereId then hereIgnoreRunning
      else ignoreRunning;
    // Use the internal function for untranslate to avoid having to do
    // extra work to negate the offset
    type strType = chpl__signedType(idxType);
    const tmpStencil = locDom.myBlock.chpl__unTranslate(wholeLow);
    var locOffset: rank*idxType;
    for param i in 1..tmpStencil.rank do
      locOffset(i) = tmpStencil.dim(i).first/tmpStencil.dim(i).stride:strType;
    // Forward to defaultRectangular
    for followThis in tmpStencil._value.these(iterKind.leader, maxTasks,
                                            myIgnoreRunning, minSize,
                                            locOffset) do
      yield followThis;
  }
}

//
// TODO: Abstract the addition of low into a function?
// Note relationship between this operation and the
// order/position functions -- any chance for creating similar
// support? (esp. given how frequent this seems likely to be?)
//
// TODO: Is there some clever way to invoke the leader/follower
// iterator on the local blocks in here such that the per-core
// parallelism is expressed at that level?  Seems like a nice
// natural composition and might help with my fears about how
// stencil communication will be done on a per-locale basis.
//
iter StencilDom.these(param tag: iterKind, followThis) where tag == iterKind.follower {
  proc anyStridable(rangeTuple, param i: int = 1) param
      return if i == rangeTuple.size then rangeTuple(i).stridable
             else rangeTuple(i).stridable || anyStridable(rangeTuple, i+1);

  if chpl__testParFlag then
    chpl__testPar("Stencil domain follower invoked on ", followThis);

  var t: rank*range(idxType, stridable=stridable||anyStridable(followThis));
  type strType = chpl__signedType(idxType);
  for param i in 1..rank {
    var stride = whole.dim(i).stride: strType;
    // not checking here whether the new low and high fit into idxType
    var low = (stride * followThis(i).low:strType):idxType;
    var high = (stride * followThis(i).high:strType):idxType;
    t(i) = ((low..high by stride:strType) + whole.dim(i).low by followThis(i).stride:strType).safeCast(t(i).type);
  }
  for i in {(...t)} {
    yield i;
  }
}

//
// output domain
//
proc StencilDom.dsiSerialWrite(x) {
  x.write(whole);
}

//
// how to allocate a new array over this domain
//
proc StencilDom.dsiBuildArray(type eltType) {
  var arr = new StencilArr(eltType=eltType, rank=rank, idxType=idxType, stridable=stridable, dom=this);
  arr.setup();
  return arr;
}

proc StencilDom.dsiNumIndices return whole.numIndices;
proc StencilDom.dsiLow return whole.low;
proc StencilDom.dsiHigh return whole.high;
proc StencilDom.dsiStride return whole.stride;

//
// INTERFACE NOTES: Could we make dsiSetIndices() for a rectangular
// domain take a domain rather than something else?
//
proc StencilDom.dsiSetIndices(x: domain) {
  if x.rank != rank then
    compilerError("rank mismatch in domain assignment");
  if x._value.idxType != idxType then
    compilerError("index type mismatch in domain assignment");
  whole = x;
  if whole.size > 0 {
    wholeFluff = whole.expand(fluff);
  }
  setup();
  if debugStencilDist {
    writeln("Setting indices of Stencil domain:");
    dsiDisplayRepresentation();
  }
}

proc StencilDom.dsiSetIndices(x) {
  if x.size != rank then
    compilerError("rank mismatch in domain assignment");
  if x(1).idxType != idxType then
    compilerError("index type mismatch in domain assignment");
  //
  // TODO: This seems weird:
  //
  whole.setIndices(x);
  if whole.size > 0 {
    wholeFluff = whole.expand(fluff);
  }
  setup();
  if debugStencilDist {
    writeln("Setting indices of Stencil domain:");
    dsiDisplayRepresentation();
  }
}

proc StencilDom.dsiGetIndices() {
  return whole.getIndices();
}

// dsiLocalSlice
proc StencilDom.dsiLocalSlice(param stridable: bool, ranges) {
  return whole((...ranges));
}

proc StencilDom.setup() {
  coforall localeIdx in dist.targetLocDom do {
    on dist.targetLocales(localeIdx) {
      ref myLocDom = locDoms(localeIdx);

      // Create a domain that points to the nearest neighboring locales
      var nearest : rank*range;
      for param i in 1..rank do nearest(i) = -1..1;
      const ND : domain(rank) = nearest;

      if myLocDom == nil {
        myLocDom = new LocStencilDom(rank, idxType, stridable,
                                             dist.getChunk(whole, localeIdx), NeighDom=ND);
      } else {
        myLocDom.myBlock = dist.getChunk(whole, localeIdx);
      }

      if !zeroTuple(fluff) && myLocDom.myBlock.numIndices!=0 then {
        myLocDom.myFluff = myLocDom.myBlock.expand(fluff);
      }
      else {
        myLocDom.myFluff = myLocDom.myBlock;
      }

      if !zeroTuple(fluff) && myLocDom.myBlock.size > 0 {
        //
        // Recompute Src and Dest domains, later used to update fluff regions
        //
        for (S, D, off) in zip(myLocDom.Src, myLocDom.Dest, ND) {
          D = myLocDom.myBlock.exterior(off * fluff);
          assert(wholeFluff.member(D.low) && wholeFluff.member(D.high), "StencilDist: Error computing destination slice.");
          if periodic then S = D;
        }

        for (N, L) in zip(myLocDom.Neighs, ND) {
          if zeroTuple(L) then continue;
          N = localeIdx + L;
        }

        if periodic {
          for (S, D, N, L) in zip(myLocDom.Src, myLocDom.Dest, myLocDom.Neighs, ND) {
            if zeroTuple(L) then continue; // Skip center

            var offset : rank*idxType;
            for i in 1..rank {
              if S.dim(i).low > whole.dim(i).high then
                offset(i) = -whole.dim(i).size;
              else if S.dim(i).high < whole.dim(i).low then
                offset(i) = whole.dim(i).size;
            }

            S = S.translate(offset);
            N = dist.targetLocsIdx(S.low);
            assert(whole.member(S.low) && whole.member(S.high), "StencilDist: Failure to compute Src slice.");
            assert(dist.targetLocDom.member(N), "StencilDist: Error computing neighbor index.");
          }
        }
      }
    }
  }
}

proc StencilDom.dsiMember(i) {
  return whole.member(i);
}

proc StencilDom.dsiIndexOrder(i) {
  return whole.indexOrder(i);
}

//
// build a new rectangular domain using the given range
//
proc StencilDom.dsiBuildRectangularDom(param rank: int, type idxType,
                                   param stridable: bool,
                                   ranges: rank*range(idxType,
                                                      BoundedRangeType.bounded,
                                                      stridable)) {
  if idxType != dist.idxType then
    compilerError("Stencil domain index type does not match distribution's");
  if rank != dist.rank then
    compilerError("Stencil domain rank does not match distribution's");

  var dom = new StencilDom(rank=rank, idxType=idxType,
                         dist=dist, stridable=stridable, fluff=fluff,
                         periodic=periodic);
  dom.dsiSetIndices(ranges);
  return dom;
}

//
// Added as a performance stopgap to avoid returning a domain
//
proc LocStencilDom.member(i) return myBlock.member(i);

proc StencilArr.dsiDisplayRepresentation() {
  for tli in dom.dist.targetLocDom {
    writeln("locArr[", tli, "].myElems = ", for e in locArr[tli].myElems do e);
    if doRADOpt then
      writeln("locArr[", tli, "].locRAD = ", locArr[tli].locRAD.RAD);
  }
}

proc StencilArr.dsiGetBaseDom() return dom;

//
// NOTE: Each locale's myElems array be initialized prior to setting up
// the RAD cache.
//
proc StencilArr.setupRADOpt() {
  for localeIdx in dom.dist.targetLocDom {
    on dom.dist.targetLocales(localeIdx) {
      const myLocArr = locArr(localeIdx);
      if myLocArr.locRAD != nil {
        delete myLocArr.locRAD;
        myLocArr.locRAD = nil;
      }
      if disableStencilLazyRAD {
        myLocArr.locRAD = new LocRADCache(eltType, rank, idxType, dom.dist.targetLocDom);
        for l in dom.dist.targetLocDom {
          if l != localeIdx {
            myLocArr.locRAD.RAD(l) = locArr(l).myElems._value.dsiGetRAD();
          }
        }
      }
    }
  }
}

proc StencilArr.setup() {
  var thisid = this.locale.id;
  var nearest : rank*range;
  for param i in 1..nearest.size do nearest(i) = -1..1;
  coforall localeIdx in dom.dist.targetLocDom {
    on dom.dist.targetLocales(localeIdx) {
      const locDom = dom.getLocDom(localeIdx);
      locArr(localeIdx) = new LocStencilArr(eltType, rank, idxType, stridable, locDom);
      if thisid == here.id then
        myLocArr = locArr(localeIdx);
    }
  }

  if doRADOpt && disableStencilLazyRAD then setupRADOpt();
}

// Re-use _remoteAccessData.getDataIndex from BlockDist


inline proc StencilArr.dsiLocalAccess(i: rank*idxType) ref {
  return myLocArr.this(i);
}

//
// the global accessor for the array
//
// TODO: Do we need a global bounds check here or in targetLocsIdx?
//
inline
proc StencilArr.do_dsiAccess(param setter, i: rank*idxType) ref {
  local {
    if myLocArr != nil {
      if setter {
        // A write: return from actual data and not fluff
        if myLocArr.locDom.member(i) then return myLocArr.this(i);
      } else {
        // A read: return from fluff if possible
        // If there is no fluff, then myFluff == myBlock
        if myLocArr.locDom.myFluff.member(i) then return myLocArr.this(i);
      }
    }
  }

  return nonLocalAccess(i);
}

proc StencilArr.nonLocalAccess(i: rank*idxType) ref {

  if doRADOpt {
    if myLocArr {
      if boundsChecking {
        if !dom.wholeFluff.member(i) {
          halt("array index out of bounds: ", i);
        }
      }
      var rlocIdx = dom.dist.targetLocsIdx(i);
      if !disableStencilLazyRAD {
        if myLocArr.locRAD == nil {
          myLocArr.lockLocRAD();
          if myLocArr.locRAD == nil {
            var tempLocRAD = new LocRADCache(eltType, rank, idxType, dom.dist.targetLocDom);
            tempLocRAD.RAD.blk = SENTINEL;
            myLocArr.locRAD = tempLocRAD;
          }
          myLocArr.unlockLocRAD();
        }
        // NOTE: This is a known, benign race.  Multiple tasks may be
        // initializing the RAD cache entries at once, but our belief is
        // that this is infrequent enough that the potential extra gets
        // are worth *not* having to synchronize.  If this turns out to be
        // an incorrect assumption, we can add an atomic variable and use
        // a fetchAdd to decide which task does the update.
        if myLocArr.locRAD.RAD(rlocIdx).blk == SENTINEL {
          myLocArr.locRAD.RAD(rlocIdx) = locArr(rlocIdx).myElems._value.dsiGetRAD();
        }
      }
      pragma "no copy" pragma "no auto destroy" var myLocRAD = myLocArr.locRAD;
      pragma "no copy" pragma "no auto destroy" var radata = myLocRAD.RAD;
      if radata(rlocIdx).shiftedData != nil {
        var dataIdx = radata(rlocIdx).getDataIndex(myLocArr.stridable, i);
        return radata(rlocIdx).shiftedData(dataIdx);
      }
    }
  }
  return locArr(dom.dist.targetLocsIdx(i))(i);
}

// ref version
inline proc StencilArr.dsiAccess(i: rank*idxType) ref {
  return do_dsiAccess(true, i);
}
// value version for POD types
inline proc StencilArr.dsiAccess(i: rank*idxType)
where !shouldReturnRvalueByConstRef(eltType) {
  return do_dsiAccess(false, i);
}
// const ref version for types with copy-ctor
inline proc StencilArr.dsiAccess(i: rank*idxType) const ref
where shouldReturnRvalueByConstRef(eltType) {
  return do_dsiAccess(false, i);
}


// ref version
inline proc StencilArr.dsiAccess(i: idxType...rank) ref
  return dsiAccess(i);
// value version for POD types
inline proc StencilArr.dsiAccess(i: idxType...rank)
where !shouldReturnRvalueByConstRef(eltType)
  return dsiAccess(i);
// const ref version for types with copy-ctor
inline proc StencilArr.dsiAccess(i: idxType...rank) const ref
where shouldReturnRvalueByConstRef(eltType)
  return dsiAccess(i);


iter StencilArr.these() ref {
  for i in dom do
    yield dsiAccess(i);
}

//
// TODO: Rewrite this to reuse more of the global domain iterator
// logic?  (e.g., can we forward the forall to the global domain
// somehow?
//
iter StencilArr.these(param tag: iterKind) where tag == iterKind.leader {
  for followThis in dom.these(tag) do
    yield followThis;
}

proc StencilArr.dsiStaticFastFollowCheck(type leadType) param
  return leadType == this.type || leadType == this.dom.type;

proc StencilArr.dsiDynamicFastFollowCheck(lead: [])
  return lead.domain._value == this.dom;

proc StencilArr.dsiDynamicFastFollowCheck(lead: domain)
  return lead._value == this.dom;

iter StencilArr.these(param tag: iterKind, followThis, param fast: bool = false) ref where tag == iterKind.follower {
  proc anyStridable(rangeTuple, param i: int = 1) param
      return if i == rangeTuple.size then rangeTuple(i).stridable
             else rangeTuple(i).stridable || anyStridable(rangeTuple, i+1);

  if chpl__testParFlag {
    if fast then
      chpl__testPar("Stencil array fast follower invoked on ", followThis);
    else
      chpl__testPar("Stencil array non-fast follower invoked on ", followThis);
  }

  if testFastFollowerOptimization then
    writeln((if fast then "fast" else "regular") + " follower invoked for Stencil array");

  var myFollowThis: rank*range(idxType=idxType, stridable=stridable || anyStridable(followThis));
  var lowIdx: rank*idxType;

  for param i in 1..rank {
    var stride = dom.whole.dim(i).stride;
    // NOTE: Not bothering to check to see if these can fit into idxType
    var low = followThis(i).low * abs(stride):idxType;
    var high = followThis(i).high * abs(stride):idxType;
    myFollowThis(i) = ((low..high by stride) + dom.whole.dim(i).low by followThis(i).stride).safeCast(myFollowThis(i).type);
    lowIdx(i) = myFollowThis(i).low;
  }

  const myFollowThisDom = {(...myFollowThis)};
  if fast {
    //
    // TODO: The following is a buggy hack that will only work when we're
    // distributing across the entire Locales array.  I still think the
    // locArr/locDoms arrays should be associative over locale values.
    //
    var arrSection = locArr(dom.dist.targetLocsIdx(lowIdx));

    //
    // if arrSection is not local and we're using the fast follower,
    // it means that myFollowThisDom is empty; make arrSection local so
    // that we can use the local block below
    //
    if arrSection.locale.id != here.id then
      arrSection = myLocArr;

    //
    // Slicing arrSection.myElems will require reference counts to be updated.
    // If myElems is an array of arrays, the inner array's domain or dist may
    // live on a different locale and require communication for reference
    // counting. Simply put: don't slice inside a local block.
    //
    var chunk => arrSection.myElems(myFollowThisDom);
    local {
      for i in chunk do yield i;
    }
  } else {
    //
    // we don't necessarily own all the elements we're following
    //
    for i in myFollowThisDom {
      yield dsiAccess(i);
    }
  }
}

//
// output array
//
proc StencilArr.dsiSerialWrite(f) {
  type strType = chpl__signedType(idxType);
  var binary = f.binary();
  if dom.dsiNumIndices == 0 then return;
  var i : rank*idxType;
  for dim in 1..rank do
    i(dim) = dom.dsiDim(dim).low;
  label next while true {
    f.write(dsiAccess(i));
    if i(rank) <= (dom.dsiDim(rank).high - dom.dsiDim(rank).stride:strType) {
      if ! binary then f.write(" ");
      i(rank) += dom.dsiDim(rank).stride:strType;
    } else {
      for dim in 1..rank-1 by -1 {
        if i(dim) <= (dom.dsiDim(dim).high - dom.dsiDim(dim).stride:strType) {
          i(dim) += dom.dsiDim(dim).stride:strType;
          for dim2 in dim+1..rank {
            f.writeln();
            i(dim2) = dom.dsiDim(dim2).low;
          }
          continue next;
        }
      }
      break;
    }
  }
}

proc StencilArr.dsiSlice(d: StencilDom) {
  var alias = new StencilArr(eltType=eltType, rank=rank, idxType=idxType, stridable=d.stridable, dom=d);
  var thisid = this.locale.id;
  coforall i in d.dist.targetLocDom {
    d.locDoms[i].myFluff = d.locDoms[i].myBlock;
    d.fluff = makeZero(d.rank);
    on d.dist.targetLocales(i) {
      alias.locArr[i] = new LocStencilArr(eltType=eltType, rank=rank, idxType=idxType, stridable=d.stridable, locDom=d.locDoms[i], myElems=>locArr[i].myElems[d.locDoms[i].myBlock]);
      if thisid == here.id then
        alias.myLocArr = alias.locArr[i];
    }
  }
  if doRADOpt then alias.setupRADOpt();
  return alias;
}

proc StencilArr.dsiLocalSlice(ranges) {
  var low: rank*idxType;
  for param i in 1..rank {
    low(i) = ranges(i).low;
  }
  var A => locArr(dom.dist.targetLocsIdx(low)).myElems((...ranges));
  return A;
}

proc _extendTuple(type t, idx: _tuple, args) {
  var tup: args.size*t;
  var j: int = 1;

  for param i in 1..args.size {
    if isCollapsedDimension(args(i)) then
      tup(i) = args(i);
    else {
      tup(i) = idx(j);
      j += 1;
    }
  }
  return tup;
}

proc _extendTuple(type t, idx, args) {
  var tup: args.size*t;
  var idxTup = (idx,);
  var j: int = 1;

  for param i in 1..args.size {
    if isCollapsedDimension(args(i)) then
      tup(i) = args(i);
    else {
      tup(i) = idxTup(j);
      j += 1;
    }
  }
  return tup;
}


proc StencilArr.dsiRankChange(d, param newRank: int, param stridable: bool, args) {
  var alias = new StencilArr(eltType=eltType, rank=newRank, idxType=idxType, stridable=stridable, dom=d);
  var thisid = this.locale.id;
  coforall ind in d.dist.targetLocDom {
    on d.dist.targetLocales(ind) {
      const locDom = d.getLocDom(ind);
      // locSlice is a tuple of ranges and scalars. It will match the basic
      // shape of the args argument. 
      var locSlice: _matchArgsShape(range(idxType=idxType, stridable=stridable), idxType, args);
      // collapsedDims stores the value any collapsed dimension is down to.
      // For any non-collapsed dimension, that position is ignored.
      // This tuple is then passed to the targetLocsIdx function to build up a
      // partial index into this.targetLocDom with correct values set for all
      // collapsed dimensions. The rest of the dimensions get their values from
      // ind - an index into the new rank changed targetLocDom.
      var collapsedDims: rank*idxType;
      var locArrInd: rank*int;

      var j = 1;
      for param i in 1..args.size {
        if isCollapsedDimension(args(i)) {
          locSlice(i) = args(i);
          collapsedDims(i) = args(i);
        } else {
          locSlice(i) = locDom.myBlock.dim(j)(args(i));
          j += 1;
        }
      }
      locArrInd = dom.dist.targetLocsIdx(collapsedDims);
      j = 1;
      // Now that the locArrInd values are known for the collapsed dimensions
      // Pull the rest of the dimensions values from ind
      for param i in 1..args.size {
        if !isCollapsedDimension(args(i)) {
          if newRank > 1 then
            locArrInd(i) = ind(j);
          else
            locArrInd(i) = ind;
          j += 1;
        }
      }

      alias.locArr[ind] =
        new LocStencilArr(eltType=eltType, rank=newRank, idxType=d.idxType,
                        stridable=d.stridable, locDom=locDom,
                        myElems=>locArr[(...locArrInd)].myElems[(...locSlice)]);

      if thisid == here.id then
        alias.myLocArr = alias.locArr[ind];
    }
  }
  if doRADOpt then alias.setupRADOpt();
  return alias;
}

private inline proc zeroTuple(t) {
  for param i in 1..t.size do 
    if t(i) != 0 then return false;
  return true;
}

iter _array.boundaries() {
  for d in _value.dsiBoundaries() do yield d;
}

iter _array.boundaries(param tag : iterKind) where tag == iterKind.standalone {
  forall d in _value.dsiBoundaries() do yield d;
}

iter StencilArr.dsiBoundaries() {
  for i in dom.dist.targetLocDom {
    var LSA = locArr[i];
    ref myLocDom = LSA.locDom;
    for (D, N, L) in zip(myLocDom.Dest, myLocDom.Neighs, myLocDom.NeighDom) {
      const target = i + L;
      const low = dom.dist.targetLocDom.low;
      const high = dom.dist.targetLocDom.high;

      if (!dom.dist.targetLocDom.member(target)) {
        var translated : target.type;
        for param r in 1..LSA.rank {
          if target(r) < low(r) {
            translated(r) = target(r);
          } else if target(r) > high(r) {
            translated(r) = target(r) - high(r);
          } else {
            translated(r) = 0;
          }
        }

        for el in LSA.myElems[D] do yield (el, translated);
      }
    }
  }
}

//
// Yields any 'fluff' boundary chunks in the StencilArr along with a global coordinate of
// where the chunk lives relative to the core.
//
iter StencilArr.dsiBoundaries(param tag : iterKind) where tag == iterKind.standalone {
  coforall i in dom.dist.targetLocDom {
    on dom.dist.targetLocales(i) {
      var LSA = locArr[i];
      ref myLocDom = LSA.locDom;
      forall (D, N, L) in zip(myLocDom.Dest, myLocDom.Neighs, myLocDom.NeighDom) {
        const target = i + L;
        const low = dom.dist.targetLocDom.low;
        const high = dom.dist.targetLocDom.high;
        //
        // if `LSA` has a cache section of the outermost fluff/boundary,
        // then we should yield that so it is updated correctly. To do
        // so, we need to translate the local offset to the global offset.
        // A 2D example:
        //
        //         |-----|-----|
        //  X=>|---|     |     |
        //     |---|-----|-----|
        //         |  A  |     |
        //         |-----|-----|
        //
        // Locale-chunk `A` knows about its cache section `X` by the
        // coordinates (-1, 1). However, `X` is globally on the (-1,0)
        // face of the grid. The logic below performs the translation
        // from the local coordinate to the global coordinate.
        //

        // If the target locale is outside the grid, it's a boundary chunk
        if (!dom.dist.targetLocDom.member(target)) {
          var translated : target.type;
          for param r in 1..LSA.rank {
            if target(r) < low(r) {
              translated(r) = target(r);
            } else if target(r) > high(r) {
              translated(r) = target(r) - high(r);
            } else {
              translated(r) = 0;
            }
          }

          // TODO: should we 'forall' over this instead?
          for el in LSA.myElems[D] do yield (el, translated);
        }
      }
    }
  }
}

// wrapper
proc _array.updateFluff() {
  _value.dsiUpdateFluff();
}

// copy over into cache
proc StencilArr.dsiUpdateFluff() {
  if zeroTuple(dom.fluff) then return;
  coforall i in dom.dist.targetLocDom {
    on dom.dist.targetLocales(i) {
      ref myLocDom = locArr[i].locDom;
      forall (S, D, N, L) in zip(myLocDom.Src, myLocDom.Dest,
          myLocDom.Neighs, myLocDom.NeighDom) {
        if !zeroTuple(L) {
          if !dom.dist.targetLocDom.member(i+L) && dom.periodic then
            locArr[i].myElems[D] = locArr[N].myElems[S];
          else if dom.dist.targetLocDom.member(N) then
            locArr[i].myElems[D] = locArr[N].myElems[D];
        }
      }
    }
  }
}

proc StencilArr.dsiReindex(d: StencilDom) {
  var alias = new StencilArr(eltType=eltType, rank=d.rank, idxType=d.idxType,
                           stridable=d.stridable, dom=d);
  const sameDom = d==dom;

  var thisid = this.locale.id;
  coforall i in d.dist.targetLocDom {
    on d.dist.targetLocales(i) {
      const locDom = d.getLocDom(i);
      var locAlias: [locDom.myBlock] => locArr[i].myElems;
      alias.locArr[i] = new LocStencilArr(eltType=eltType,
                                        rank=rank, idxType=d.idxType,
                                        stridable=d.stridable,
                                        locDom=locDom,
                                        myElems=>locAlias);
      if thisid == here.id then
        alias.myLocArr = alias.locArr[i];
      if doRADOpt {
        if sameDom {
          // If we the reindex domain is the same as that of this array,
          //  the RAD cache will be the same you can just copy the values
          //  directly into the alias's RAD cache
          if locArr[i].locRAD {
            alias.locArr[i].locRAD = new LocRADCache(eltType, rank, idxType,
                                                     dom.dist.targetLocDom);
            alias.locArr[i].locRAD.RAD = locArr[i].locRAD.RAD;
          }
        }
      }
    }
  }

  if doRADOpt then
    if !sameDom then alias.setupRADOpt();

  return alias;
}

proc StencilArr.dsiReallocate(d: domain) {
  //
  // For the default rectangular array, this function changes the data
  // vector in the array class so that it is setup once the default
  // rectangular domain is changed.  For this distributed array class,
  // we don't need to do anything, because changing the domain will
  // change the domain in the local array class which will change the
  // data in the local array class.  This will only work if the domain
  // we are reallocating to has the same distribution, but domain
  // assignment is defined so that only the indices are transferred.
  // The distribution remains unchanged.
  //
}

proc StencilArr.dsiPostReallocate() {
  // Call this *after* the domain has been reallocated
  if doRADOpt then setupRADOpt();
}

proc StencilArr.setRADOpt(val=true) {
  doRADOpt = val;
  if doRADOpt then setupRADOpt();
}

//
// the accessor for the local array -- assumes the index is local
//
proc LocStencilArr.this(i) ref {
  return myElems(i);
}

//
// Privatization
//
proc Stencil.Stencil(other: Stencil, privateData,
                param rank = other.rank,
                type idxType = other.idxType) {
  boundingBox = {(...privateData(1))};
  targetLocDom = {(...privateData(2))};
  dataParTasksPerLocale = privateData(3);
  dataParIgnoreRunningTasks = privateData(4);
  dataParMinGranularity = privateData(5);
  fluff = privateData(6);
  periodic = privateData(7);

  for i in targetLocDom {
    targetLocales(i) = other.targetLocales(i);
    locDist(i) = other.locDist(i);
  }
}

proc Stencil.dsiSupportsPrivatization() param return true;

proc Stencil.dsiGetPrivatizeData() {
  return (boundingBox.dims(), targetLocDom.dims(),
          dataParTasksPerLocale, dataParIgnoreRunningTasks, dataParMinGranularity,
          fluff, periodic);
}

proc Stencil.dsiPrivatize(privatizeData) {
  return new Stencil(this, privatizeData);
}

proc Stencil.dsiGetReprivatizeData() return boundingBox.dims();

proc Stencil.dsiReprivatize(other, reprivatizeData) {
  boundingBox = {(...reprivatizeData)};
  targetLocDom = other.targetLocDom;
  targetLocales = other.targetLocales;
  locDist = other.locDist;
  dataParTasksPerLocale = other.dataParTasksPerLocale;
  dataParIgnoreRunningTasks = other.dataParIgnoreRunningTasks;
  dataParMinGranularity = other.dataParMinGranularity;
}

proc StencilDom.dsiSupportsPrivatization() param return true;

proc StencilDom.dsiGetPrivatizeData() return (dist.pid, whole.dims());

proc StencilDom.dsiPrivatize(privatizeData) {
  var privdist = chpl_getPrivatizedCopy(dist.type, privatizeData(1));
  var c = new StencilDom(rank=rank, idxType=idxType, stridable=stridable, dist=privdist, fluff=fluff, periodic=periodic);
  for i in c.dist.targetLocDom do
    c.locDoms(i) = locDoms(i);
  c.whole = {(...privatizeData(2))};
  if c.whole.size > 0 {
    c.wholeFluff = c.whole.expand(fluff);
  }
  return c;
}

proc StencilDom.dsiGetReprivatizeData() return whole.dims();

proc StencilDom.dsiReprivatize(other, reprivatizeData) {
  for i in dist.targetLocDom do
    locDoms(i) = other.locDoms(i);
  whole = {(...reprivatizeData)};
  if whole.size > 0 {
    wholeFluff = whole.expand(fluff);
  }
}

proc StencilArr.dsiSupportsPrivatization() param return true;

proc StencilArr.dsiGetPrivatizeData() return dom.pid;

proc StencilArr.dsiPrivatize(privatizeData) {
  var privdom = chpl_getPrivatizedCopy(dom.type, privatizeData);
  var c = new StencilArr(eltType=eltType, rank=rank, idxType=idxType, stridable=stridable, dom=privdom);
  for localeIdx in c.dom.dist.targetLocDom {
    c.locArr(localeIdx) = locArr(localeIdx);
    if c.locArr(localeIdx).locale.id == here.id then
      c.myLocArr = c.locArr(localeIdx);
  }
  return c;
}

proc StencilArr.dsiSupportsBulkTransfer() param return true;
proc StencilArr.dsiSupportsBulkTransferInterface() param return true;

proc StencilArr.doiCanBulkTransfer() {
  if debugStencilDistBulkTransfer then
    writeln("In StencilArr.doiCanBulkTransfer");

  if dom.stridable then
    for param i in 1..rank do
      if dom.whole.dim(i).stride != 1 then return false;

  // See above note regarding aliased arrays
  if disableAliasedBulkTransfer then
    if _arrAlias != nil then return false;

  return true;
}

proc StencilArr.doiCanBulkTransferStride() param {
  if debugStencilDistBulkTransfer then
    writeln("In StencilArr.doiCanBulkTransferStride");

  // A StencilArr is a bunch of DefaultRectangular arrays,
  // so strided bulk transfer gotta be always possible.
  return true;
}

proc StencilArr.doiBulkTransfer(B) {
  if debugStencilDistBulkTransfer then
    writeln("In StencilArr.doiBulkTransfer");

  if debugStencilDistBulkTransfer then resetCommDiagnostics();
  var sameDomain: bool;
  // We need to do the following on the locale where 'this' was allocated,
  //  but hopefully, most of the time we are initiating the transfer
  //  from the same locale (local on clauses are optimized out).
  on this do sameDomain = dom==B._value.dom;
  // Use zippered iteration to piggyback data movement with the remote
  //  fork.  This avoids remote gets for each access to locArr[i] and
  //  B._value.locArr[i]
  coforall (i, myLocArr, BmyLocArr) in zip(dom.dist.targetLocDom,
                                        locArr,
                                        B._value.locArr) do
    on dom.dist.targetLocales(i) {

    if sameDomain &&
      chpl__useBulkTransfer(myLocArr.myElems, BmyLocArr.myElems) {
      // Take advantage of DefaultRectangular bulk transfer
      if debugStencilDistBulkTransfer then startCommDiagnosticsHere();
      local {
        myLocArr.myElems._value.doiBulkTransfer(BmyLocArr.myElems);
      }
      if debugStencilDistBulkTransfer then stopCommDiagnosticsHere();
    } else {
      if debugStencilDistBulkTransfer then startCommDiagnosticsHere();
      if (rank==1) {
        var lo=dom.locDoms[i].myBlock.low;
        const start=lo;
        //use divCeilPos(i,j) to know the limits
        //but i and j have to be positive.
        for (rid, rlo, size) in ConsecutiveChunks(dom,B._value.dom,i,start) {
          if debugStencilDistBulkTransfer then writeln("Local Locale id=",i,
                                            "; Remote locale id=", rid,
                                            "; size=", size,
                                            "; lo=", lo,
                                            "; rlo=", rlo
                                            );
          // NOTE: This does not work with --heterogeneous, but heterogeneous
          // compilation does not work right now.  This call should be changed
          // once that is fixed.
          var dest = myLocArr.myElems._value.theData;
          const src = B._value.locArr[rid].myElems._value.theData;
          __primitive("chpl_comm_array_get",
                      __primitive("array_get", dest,
                                  myLocArr.myElems._value.getDataIndex(lo)),
                      rid,
                      __primitive("array_get", src,
                                  B._value.locArr[rid].myElems._value.getDataIndex(rlo)),
                      size);
          lo+=size;
        }
      } else {
        var orig=dom.locDoms[i].myBlock.low(dom.rank);
        for coord in dropDims(dom.locDoms[i].myBlock, dom.locDoms[i].myBlock.rank) {
          var lo=if rank==2 then (coord,orig) else ((...coord), orig);
          const start=lo;
          for (rid, rlo, size) in ConsecutiveChunksD(dom,B._value.dom,i,start) {
            if debugStencilDistBulkTransfer then writeln("Local Locale id=",i,
                                        "; Remote locale id=", rid,
                                        "; size=", size,
                                        "; lo=", lo,
                                        "; rlo=", rlo
                                        );
          var dest = myLocArr.myElems._value.theData;
          const src = B._value.locArr[rid].myElems._value.theData;
          __primitive("chpl_comm_array_get",
                      __primitive("array_get", dest,
                                  myLocArr.myElems._value.getDataIndex(lo)),
                      dom.dist.targetLocales(rid).id,
                      __primitive("array_get", src,
                                  B._value.locArr[rid].myElems._value.getDataIndex(rlo)),
                      size);
            lo(rank)+=size;
          }
        }
      }
      if debugStencilDistBulkTransfer then stopCommDiagnosticsHere();
    }
  }
  if debugStencilDistBulkTransfer then writeln("Comms:",getCommDiagnostics());
}

proc StencilArr.dsiTargetLocales() {
  return dom.dist.targetLocales;
}

proc StencilDom.dsiTargetLocales() {
  return dist.targetLocales;
}

proc Stencil.dsiTargetLocales() {
  return targetLocales;
}

// Stencil subdomains are continuous

proc StencilArr.dsiHasSingleLocalSubdomain() param return true;
proc StencilDom.dsiHasSingleLocalSubdomain() param return true;

// returns the current locale's subdomain

proc StencilArr.dsiLocalSubdomain() {
  return myLocArr.locDom.myBlock;
}
proc StencilDom.dsiLocalSubdomain() {
  // TODO -- could be replaced by a privatized myLocDom in StencilDom
  // as it is with StencilArr
  var myLocDom:LocStencilDom(rank, idxType, stridable) = nil;
  for (loc, locDom) in zip(dist.targetLocales, locDoms) {
    if loc == here then
      myLocDom = locDom;
  }
  return myLocDom.myBlock;
}

proc StencilDom.numRemoteElems(rlo,rid){
  // NOTE: Not bothering to check to see if rid+1, length, or rlo-1 used
  //  below can fit into idxType
  var blo,bhi:dist.idxType;
  if rid==(dist.targetLocDom.dim(rank).length - 1) then
    bhi=whole.dim(rank).high;
  else
      bhi=dist.boundingBox.dim(rank).low +
        intCeilXDivByY((dist.boundingBox.dim(rank).high - dist.boundingBox.dim(rank).low +1)*(rid+1):idxType,
                       dist.targetLocDom.dim(rank).length:idxType) - 1:idxType;

  return(bhi - (rlo - 1):idxType);
}

//For assignments of the form: "any = Stencil"
//Currently not used, instead we use: doiBulkTransferFrom()
proc StencilArr.doiBulkTransferTo(Barg)
{
  if debugStencilDistBulkTransfer then
    writeln("In StencilArr.doiBulkTransferTo()");
  
  const B = this, A = Barg._value;
  type el = B.idxType;
  coforall i in B.dom.dist.targetLocDom do // for all locales
    on B.dom.dist.targetLocales(i)
      {
        var regionB = B.dom.locDoms(i).myBlock;
        if regionB.numIndices>0
        {
          const ini=bulkCommConvertCoordinate(regionB.first, B, A);
          const end=bulkCommConvertCoordinate(regionB.last, B, A);
          const sa=chpl__tuplify(A.dom.locDoms(i).myBlock.stride);
          
          var r1,r2: rank * range(idxType = el,stridable = true);
          r2=regionB.dims();
           //In the case that the number of elements in dimension t for r1 and r2
           //were different, we need to calculate the correct stride in r1
          for param t in 1..rank {
            r1[t] = (ini[t]:el..end[t]:el by sa[t]:el);
            if r1[t].length != r2[t].length then
              r1[t] = (ini[t]:el..end[t]:el by (end[t] - ini[t]):el/(r2[t].length-1));
          }
        
          if debugStencilDistBulkTransfer then
            writeln("A",(...r1),".FromDR",regionB);
    
          Barg[(...r1)]._value.doiBulkTransferFromDR(B.locArr[i].myElems);
        }
      }
}

//For assignments of the form: "Stencil = any" 
//where "any" means any array that implements the bulk transfer interface
proc StencilArr.doiBulkTransferFrom(Barg)
{
  if debugStencilDistBulkTransfer then
    writeln("In StencilArr.doiBulkTransferFrom()");
 
  const A = this, B = Barg._value;
  type el = A.idxType;
  coforall i in A.dom.dist.targetLocDom do // for all locales
    on A.dom.dist.targetLocales(i)
    {
      var regionA = A.dom.locDoms(i).myBlock;
      if regionA.numIndices>0
      {
        const ini=bulkCommConvertCoordinate(regionA.first, A, B);
        const end=bulkCommConvertCoordinate(regionA.last, A, B);
        const sb=chpl__tuplify(B.dom.locDoms(i).myBlock.stride);
        
        var r1,r2: rank * range(idxType = el,stridable = true);
        r2=regionA.dims();
         //In the case that the number of elements in dimension t for r1 and r2
         //were different, we need to calculate the correct stride in r1
        for param t in 1..rank{
            r1[t] = (ini[t]:el..end[t]:el by sb[t]:el);
            if r1[t].length != r2[t].length then
              r1[t] = (ini[t]:el..end[t]:el by (end[t] - ini[t]):el/(r2[t].length-1));
        }
      
        if debugStencilDistBulkTransfer then
            writeln("B{",(...r1),"}.ToDR",regionA);
   
        Barg[(...r1)]._value.doiBulkTransferToDR(A.locArr[i].myElems[regionA]);
      }
    }
}
 
//For assignments of the form: DR = Stencil 
//(default rectangular array = block distributed array)
proc StencilArr.doiBulkTransferToDR(Barg)
{
  if debugStencilDistBulkTransfer then
    writeln("In StencilArr.doiBulkTransferToDR()");

  const A = this, B = Barg._value; //Always it is a DR
  type el = A.idxType;
  coforall j in A.dom.dist.targetLocDom do
    on A.dom.dist.targetLocales(j)
    {
      const inters=A.dom.locDoms(j).myBlock;
      if(inters.numIndices>0)
      {
        const ini=bulkCommConvertCoordinate(inters.first, A, B);
        const end=bulkCommConvertCoordinate(inters.last, A, B);
        const sa = chpl__tuplify(B.dom.dsiStride);
  
        var r1,r2: rank * range(idxType = el,stridable = true);
        for param t in 1..rank
        {
          r2[t] = (chpl__tuplify(inters.first)[t]
                   ..chpl__tuplify(inters.last)[t]
                   by chpl__tuplify(inters.stride)[t]);
          r1[t] = (ini[t]:el..end[t]:el by sa[t]:el);
        }
        
        if debugStencilDistBulkTransfer then
          writeln("A[",r1,"] = B[",r2,"]");
      
        const d ={(...r1)};
        const slice = B.dsiSlice(d._value);
        //Necessary to calculate the value of blk variable in DR
        //with the new domain r1
        slice.adjustBlkOffStrForNewDomain(d._value, slice);
        
        slice.doiBulkTransferStride(A.locArr[j].myElems[(...r2)]._value);
        
        delete slice;
      }
    }
}

//For assignments of the form: Stencil = DR 
//(block distributed array = default rectangular)
proc StencilArr.doiBulkTransferFromDR(Barg) 
{
  if debugStencilDistBulkTransfer then
    writeln("In StencilArr.doiBulkTransferFromDR");

  const A = this, B = Barg._value;
  type el = A.idxType;
  coforall j in A.dom.dist.targetLocDom do
    on A.dom.dist.targetLocales(j)
    {
      const inters=A.dom.locDoms(j).myBlock;
      if(inters.numIndices>0)
      {
        const ini=bulkCommConvertCoordinate(inters.first, A, B);
        const end=bulkCommConvertCoordinate(inters.last, A, B);
        const sb = chpl__tuplify(B.dom.dsiStride);
        
        var r1,r2: rank * range(idxType = el,stridable = true);
        for param t in 1..rank
        {
          r2[t] = (chpl__tuplify(inters.first)[t]
                   ..chpl__tuplify(inters.last)[t]
                   by chpl__tuplify(inters.stride)[t]);
          r1[t] = (ini[t]:el..end[t]:el by sb[t]:el);
        }
        
        if debugStencilDistBulkTransfer then
          writeln("A[",r2,"] = B[",r1,"]");
          
        const d ={(...r1)};
        const slice = B.dsiSlice(d._value);
        //this step it's necessary to calculate the value of blk variable in DR
        //with the new domain r1
        slice.adjustBlkOffStrForNewDomain(d._value, slice);
        
        A.locArr[j].myElems[(...r2)]._value.doiBulkTransferStride(slice);
        delete slice;
      }
    }
}
