/*
 * Copyright 2004-2015 Cray Inc.
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

#ifndef _chpl_rt_vector_macro_h_
#define _chpl_rt_vector_macro_h_

#include "chpl-comp-detect-macros.h"

// Cray has supported ivdep since at least version 6 (released 2007.) We could
// get away without a version check since the compiler isn't released outside
// of the PrgEnv, but it doesn't hurt.
#if RT_COMP_CC == RT_COMP_CRAY && RT_COMP_CRAY_VERSION_MAJOR >= 6
#define CHPL_PRAGMA_IVDEP _Pragma ("ivdep")

// Intel has supported ivdep since at least version 9 (released 2005.) It's
// possible previous versions did too, but that's far enough back for us.
#elif RT_COMP_CC == RT_COMP_INTEL && RT_COMP_INTEL_VERSION >= 900
#define CHPL_PRAGMA_IVDEP _Pragma ("ivdep")

// I didn't find an equivalent for clang version 3.6 (released 2015.) They have
// a vectorize pragma, but that just manually enables/disables vectorization on
// a specific loop, it doesn't provide the compiler with any more information
#elif RT_COMP_CC == RT_COMP_CLANG
#define CHPL_PRAGMA_IVDEP

// PGI has supported "nodepchk" since at least version 6 (released 2005.) ivdep
// is only supported for the fortran compiler, but nodepchk has identical
// semantics and is availble for C/C++ as well.
#elif RT_COMP_CC == RT_COMP_PGI && RT_COMP_PGI_VERSION_MAJOR >= 6
#define CHPL_PRAGMA_IVDEP _Pragma("nodepchk")

// GCC has only supportd ivdep since version 4.9 (released 2014.)
#elif RT_COMP_CC == RT_COMP_GCC && RT_COMP_GCC_VERSION >= 40900
#define CHPL_PRAGMA_IVDEP _Pragma ("GCC ivdep")

#else
#define CHPL_PRAGMA_IVDEP
#endif

#endif //_chpl_rt_vector_macro_h
