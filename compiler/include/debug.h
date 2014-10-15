#ifndef _DEBUG_H_
#define _DEBUG_H_

#include "type.h"

#ifdef HAVE_LLVM

#include "llvmUtil.h"
#include "llvm/Support/Dwarf.h"
#include "llvm/DebugInfo.h"
#include "llvm/DIBuilder.h"

#include <vector>

//#define DW_LANG_chapel (llvm::dwarf::DW_LANG_lo_user+37)
#define DW_LANG_chapel llvm::dwarf::DW_LANG_lo_user
#endif

struct lessAstr {
  bool operator() (const char* lhs, const char* rhs) const {
    return strcmp(lhs,rhs) < 0;
  }
};

class debug_data
{
#ifdef HAVE_LLVM
 public:
  static bool can_debug() { return true; }
  debug_data(llvm::Module &m) : dibuilder(m){}
  void finalize(){dibuilder.finalize();}
  void create_compile_unit(const char *file, const char *directory, bool is_optimized, const char *flags);

  llvm::DIType construct_type(Type *type);
  llvm::DIType get_type(Type *type);

  llvm::DIFile construct_file(const char *file);
  llvm::DIFile get_file(const char *file);

  llvm::DINameSpace construct_module_scope(ModuleSymbol* modSym);
  llvm::DINameSpace get_module_scope(ModuleSymbol* modSym);

  llvm::DIType get_function_type(FnSymbol *function);
  llvm::DISubprogram construct_function(FnSymbol *function);
  llvm::DISubprogram get_function(FnSymbol *function);

 private:
  llvm::DIBuilder dibuilder;
  bool optimized;
  //std::vector<llvm::DIFile>files;
  std::map<const char*,llvm::DIFile,lessAstr> filesByName;
  //std::vector<llvm::DIType>types;
  //std::map<const char*,llvm::DIType,lessAstr> typesByName;
  //std::vector<llvm::DINameSpace>name_spaces;
  //std::map<const char*,llvm::DINameSpace,lessAstr> modulesByName;
  //std::vector<llvm::DISubprogram>functions;
#else
  static bool can_debug() { return false; }
#endif
};

extern debug_data *debug_info;

#endif
