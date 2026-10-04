// MIT: native, disposable-process GUI self-test. No production dictionaries,
// microphone, network, clipboard or app insertion. Uses the pinned public API.
#include <algorithm>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include "rime_api.h"
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#else
#include <dlfcn.h>
#endif
namespace fs = std::filesystem;
static void need(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}
static std::string quote(const std::string& s) {
  std::ostringstream out; out << '"';
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') out << '\\' << c;
    else if (c < 32) {
      const char* hex = "0123456789abcdef";
      out << "\\u00" << hex[c >> 4] << hex[c & 15];
    } else out << c;
  }
  out << '"'; return out.str();
}
static std::string value(const char* s) { return s ? s : ""; }
static void write(const fs::path& file, const std::string& contents) {
  std::ofstream out(file, std::ios::binary | std::ios::trunc);
  need(bool(out), "cannot create isolated fixture file");
  out << contents; out.close(); need(bool(out), "isolated fixture write failed");
}
static void copyFixture(const fs::path& from, const fs::path& to) {
  need(fs::is_regular_file(from) && !fs::is_symlink(from), "fixture resource missing or symlinked");
  need(fs::file_size(from) <= 1024 * 1024, "fixture resource too large");
  need(fs::copy_file(from,to), "fixture copy failed"); // Never overwrite.
}
static RimeApi* load(const fs::path& library) {
  need(library.is_absolute() && fs::is_regular_file(library), "absolute librime path required");
#ifdef _WIN32
  auto module = LoadLibraryExW(library.c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
  need(module != nullptr, "librime DLL load failed");
  auto entry = reinterpret_cast<RimeApi* (*)()>(GetProcAddress(module,"rime_get_api"));
#else
  auto module = dlopen(library.c_str(),RTLD_NOW | RTLD_GLOBAL);
  need(module != nullptr, "librime dylib load failed");
  // Some distributions have Lua as a separate plugin, others link it in.
  for (const auto& dir : {library.parent_path(),library.parent_path()/"rime-plugins"})
    for (const char* name : {"librime-lua.dylib","librime-lua.1.dylib"}) {
      auto plugin = dir/name;
      if (fs::is_regular_file(plugin)) need(dlopen(plugin.c_str(),RTLD_NOW | RTLD_GLOBAL) != nullptr,"Lua plugin load failed");
    }
  auto entry = reinterpret_cast<RimeApi* (*)()>(dlsym(module,"rime_get_api"));
#endif
  need(entry != nullptr,"rime_get_api unavailable");
  auto api = entry();
#define CHECK_API(member) need(RIME_PROVIDED(api,member),"librime API unavailable: " #member)
  CHECK_API(setup); CHECK_API(initialize); CHECK_API(finalize); CHECK_API(find_module);
  CHECK_API(get_version); CHECK_API(deploy_config_file); CHECK_API(deploy_schema);
  CHECK_API(create_session); CHECK_API(destroy_session); CHECK_API(select_schema);
  CHECK_API(get_input); CHECK_API(process_key); CHECK_API(clear_composition);
  CHECK_API(set_option); CHECK_API(get_option); CHECK_API(get_property);
  CHECK_API(get_context); CHECK_API(free_context); CHECK_API(get_commit); CHECK_API(free_commit);
  CHECK_API(select_candidate_on_current_page);
  CHECK_API(schema_open); CHECK_API(config_get_bool); CHECK_API(config_close);
  CHECK_API(get_user_data_dir); CHECK_API(get_shared_data_dir);
#undef CHECK_API
  return api; // Keep modules loaded until process exit; no unsafe dlclose order.
}
struct Frame {
  std::string input,phase,commit,preedit,keys,error;
  int page=0,size=0,highlight=0; bool hidden=false,last=false;
  std::vector<std::string> candidates;
  std::string json() const {
    std::ostringstream out;
    out << "{\"input\":" << quote(input) << ",\"phase\":" << quote(phase)
        << ",\"commit\":" << quote(commit) << ",\"preedit\":" << quote(preedit)
        << ",\"keys\":" << quote(keys) << ",\"page\":" << page << ",\"size\":" << size
        << ",\"highlight\":" << highlight << ",\"hidden\":" << (hidden?"true":"false")
        << ",\"last\":" << (last?"true":"false") << ",\"candidates\":[";
    for (size_t i=0;i<candidates.size();++i) { if(i) out << ','; out << quote(candidates[i]); }
    out << "]}"; return out.str();
  }
};
struct Harness {
  RimeApi* api; RimeSessionId sid=0; std::vector<std::string> steps; bool lastHandled=false;
  explicit Harness(RimeApi* a):api(a) {}
  ~Harness() { if(sid) { api->clear_composition(sid); api->destroy_session(sid); } }
  std::string property(const char* name) {
    char buffer[4096]={0}; api->get_property(sid,name,buffer,sizeof(buffer)); return buffer;
  }
  Frame read() {
    Frame f; f.input=value(api->get_input(sid)); f.phase=property("_letter_selection_phase");
    f.error=property("_letter_selection_error"); need(f.error.empty(),"Lua reported configuration/API error");
    f.hidden=api->get_option(sid,"_hide_candidate") != 0;
    RimeContext ctx{}; RIME_STRUCT_INIT(RimeContext,ctx);
    if (api->get_context(sid,&ctx)) {
      f.preedit=value(ctx.composition.preedit); f.page=ctx.menu.page_no; f.size=ctx.menu.page_size;
      f.keys=value(ctx.menu.select_keys); f.highlight=ctx.menu.highlighted_candidate_index;
      f.last=ctx.menu.is_last_page != 0;
      if (ctx.menu.num_candidates < 0 || ctx.menu.num_candidates > 9) {
        api->free_context(&ctx); throw std::runtime_error("candidate count outside configured bounds");
      }
      for (int i=0;i<ctx.menu.num_candidates;++i) f.candidates.push_back(value(ctx.menu.candidates[i].text));
      api->free_context(&ctx);
    }
    RimeCommit commit{}; RIME_STRUCT_INIT(RimeCommit,commit);
    if(api->get_commit(sid,&commit)) { f.commit=value(commit.text); api->free_commit(&commit); }
    return f;
  }
  void start() {
    if(sid) { api->clear_composition(sid); api->destroy_session(sid); sid=0; }
    sid=api->create_session(); need(sid != 0,"session creation failed");
    need(api->select_schema(sid,"letter_fixture"),"fixture schema unavailable");
    api->set_option(sid,"ascii_mode",false);
  }
  Frame key(int code,int mask=0,bool requireHandled=true) {
    bool handled=api->process_key(sid,code,mask) != 0; lastHandled=handled; auto f=read();
    steps.push_back("{\"keycode\":"+std::to_string(code)+",\"mask\":"+std::to_string(mask)+",\"handled\":"+(handled?"true":"false")+",\"state\":"+f.json()+"}");
    if(requireHandled) need(handled,"key was not consumed by Rime"); return f;
  }
  Frame type(const std::string& text) {
    Frame f;
    for(unsigned char c:text) { f=key(c); need(f.commit.empty(),"pinyin typing unexpectedly committed"); }
    return f;
  }
  Frame arm(const std::string& input="ni") {
    start(); type(input); auto f=key(32);
    need(f.phase=="selecting" && f.commit.empty() && !f.candidates.empty(),"fixture could not enter explicit selection state");
    return f;
  }
};
struct Row { std::string name,status,error; std::vector<std::string> steps; };
struct Runtime { RimeApi* api; ~Runtime() { api->finalize(); } };
static int run(const std::vector<std::string>& args) {
  std::vector<Row> rows; RimeApi* api=nullptr;
  std::string fatal,version,keys; bool hide=true; int passed=0,failed=0,skipped=0;
  try {
    need(args.size()==6,"usage: SquirrelLetterProbe absolute-library absolute-resources NEW-absolute-work lowercase-keys true|false");
    keys=args[4]; hide=args[5]=="true";
    need(args[5]=="true" || args[5]=="false","invalid hide setting");
    need(!keys.empty() && keys.size()<=9 && std::set<char>(keys.begin(),keys.end()).size()==keys.size() &&
      std::all_of(keys.begin(),keys.end(),[](char c){return c>='a' && c<='z';}),"keys must be 1-9 unique lowercase letters");
    auto library=fs::u8path(args[1]),resource=fs::u8path(args[2]),work=fs::u8path(args[3]);
    need(resource.is_absolute() && work.is_absolute() && !fs::exists(work),"fresh absolute test directory required; refusing existing path");
    need(fs::create_directory(work),"fresh directory creation failed");
    auto shared=work/"shared",user=work/"user"; fs::create_directory(shared); fs::create_directory(user);
    copyFixture(resource/"letter_fixture.schema.yaml",shared/"letter_fixture.schema.yaml");
    copyFixture(resource/"letter_fixture.dict.yaml",shared/"letter_fixture.dict.yaml");
    fs::create_directory(user/"lua");
    copyFixture(resource.parent_path()/"letter_selection.lua",user/"lua/letter_selection.lua");
    copyFixture(shared/"letter_fixture.schema.yaml",user/"letter_fixture.schema.yaml");
    write(shared/"default.yaml","config_version: '1'\nschema_list:\n  - schema: letter_fixture\n");
    write(user/"letter_fixture.custom.yaml","patch:\n  engine/processors/@before 0: lua_processor@*letter_selection\n  menu/page_size: "+std::to_string(keys.size())+"\n  letter_selection/enabled: true\n  letter_selection/keys: "+keys+"\n  letter_selection/hide_candidates: "+(hide?"true":"false")+"\n");
    api=load(library);
    auto sharedName=shared.u8string(),userName=user.u8string(),logName=(work/"logs").u8string(); fs::create_directory(work/"logs");
#ifdef _WIN32
    need(_putenv_s("RIME_LOG_DIR",logName.c_str())==0,"cannot isolate plugin log directory");
#else
    need(setenv("RIME_LOG_DIR",logName.c_str(),1)==0,"cannot isolate plugin log directory");
#endif
    const char* modules[]={"default","lua","deployer",nullptr};
    RimeTraits traits{}; RIME_STRUCT_INIT(RimeTraits,traits); traits.shared_data_dir=sharedName.c_str(); traits.user_data_dir=userName.c_str();
    traits.log_dir=logName.c_str(); traits.min_log_level=2; traits.app_name="rime.enhanced_letter_probe";
    traits.distribution_name="Isolated fixture"; traits.distribution_code_name="letter_probe";
    traits.distribution_version="1"; traits.modules=modules;
    api->setup(&traits); api->initialize(&traits); Runtime runtime{api};
    need(fs::equivalent(fs::u8path(value(api->get_user_data_dir())),user) &&
         fs::equivalent(fs::u8path(value(api->get_shared_data_dir())),shared),"actual Rime data directories are not isolated");
    need(api->find_module("lua") != nullptr,"actual Lua module unavailable"); version=value(api->get_version());
    need(api->deploy_config_file("default.yaml","config_version"),"fixture default deployment failed");
    need(api->deploy_schema((user/"letter_fixture.schema.yaml").u8string().c_str()),"fixture schema deployment failed");
    RimeConfig config={}; need(api->schema_open("letter_fixture",&config),"deployed fixture config unavailable");
    Bool learning=true; bool checked=api->config_get_bool(&config,"translator/enable_user_dict",&learning) != 0;
    api->config_close(&config); need(checked && !learning,"fixture must disable user dictionary learning");
    Harness h(api);
    auto test=[&](const char* name,const std::function<void()>& body) {
      Row r; r.name=name; h.steps.clear();
      try { body(); r.status="PASS"; ++passed; }
      catch(const std::exception& e) { r.status="FAIL"; r.error=e.what(); ++failed; }
      r.steps=h.steps; rows.push_back(r);
    };
    test("pinyin_and_first_space",[&] {
      h.start(); auto before=h.type("nihao"); need(before.input=="nihao" && before.phase=="editing" && !before.preedit.empty(),"normal pinyin editing lost");
      need(before.hidden==hide,"editing candidate visibility mismatch"); auto after=h.key(32);
      need(after.commit.empty() && after.input==before.input && after.phase=="selecting" && !after.hidden && !after.candidates.empty(),"first Space committed/changed/failed to reveal");
      need(after.keys==keys && after.size==int(keys.size()),"labels or page size mismatch");
    });
    test("alphabet_is_pinyin_before_selection",[&] { h.start(); auto f=h.type("abcdefghijklmnopqrstuvwxyz"); need(f.input=="abcdefghijklmnopqrstuvwxyz" && f.phase!="selecting","alphabet was intercepted before entry"); });
    test("selection_letters_current_page",[&] {
      for(size_t i=0;i<keys.size();++i) { auto f=h.arm(); need(f.candidates.size()>i,"first page too short"); auto expected=f.candidates[i]; auto result=h.key(keys[i]); need(result.commit==expected && result.input.empty() && result.phase=="off","letter chose wrong candidate or left input"); }
    });
    test("second_space_confirms_highlight",[&] { auto f=h.arm(); if(keys.size()>1) f=h.key(0xff54); need(size_t(f.highlight)<f.candidates.size(),"highlight outside page"); auto expected=f.candidates[f.highlight]; auto result=h.key(32); need(result.commit==expected && result.input.empty(),"second Space ignored highlight"); });
    test("second_page_letter",[&] { auto first=h.arm(); auto second=h.key(0xff56); need(second.page==1 && second.phase=="selecting" && second.candidates!=first.candidates,"not on second page"); size_t i=std::min(size_t(1),keys.size()-1); need(second.candidates.size()>i,"second page too short"); auto expected=second.candidates[i]; auto result=h.key(keys[i]); need(result.commit==expected && result.input.empty(),"letter selected first page or leaked"); });
    if(keys.size()==1) { rows.push_back({"last_page_missing_item","N/A","page size 1 cannot have a nonempty partial page",{}}); ++skipped; }
    else test("last_page_missing_item",[&] { auto f=h.arm(); for(int i=0;i<30 && !f.last;++i) f=h.key(0xff56); need(f.last && !f.candidates.empty() && f.candidates.size()<keys.size(),"fixture has no partial last page"); auto input=f.input; auto missing=f.candidates.size(); auto result=h.key(keys[missing]); need(result.commit.empty() && result.input==input && result.page==f.page && result.phase=="selecting","missing letter selected or leaked"); result=h.key('1'+int(missing)); need(result.commit.empty() && result.input==input && result.page==f.page,"missing numeric selected or leaked"); });
    test("escape_retains_input",[&] { h.arm("nihao"); auto f=h.key(0xff1b); need(f.input=="nihao" && f.commit.empty() && f.phase=="editing" && f.hidden==hide,"Escape lost input or state"); });
    test("backspace_exactly_once",[&] { h.arm("nihao"); auto f=h.key(0xff08); need(f.input=="niha" && f.commit.empty() && f.phase=="editing","BackSpace not exactly once"); });
    test("numeric_current_page",[&] { auto f=h.arm(); auto expected=f.candidates[0]; auto result=h.key('1'); need(result.commit==expected && result.input.empty(),"numeric selection broken"); });
    test("mouse_current_page_API",[&] { auto f=h.arm(); f=h.key(0xff56); auto expected=f.candidates[0]; need(api->select_candidate_on_current_page(h.sid,0),"native current-page mouse selection API rejected"); auto result=h.read(); h.steps.push_back("{\"mouse_API_state\":"+result.json()+"}"); need(result.commit==expected && result.input.empty(),"mouse API did not select current page"); });
    test("sentence_partial_selection",[&] { auto f=h.arm("nihaoshijie"); int index=-1; for(size_t i=0;i<f.candidates.size();++i) if(f.candidates[i]=="你好") index=int(i); for(int page=0;index<0 && !f.last && page<30;++page) { f=h.key(0xff56); for(size_t i=0;i<f.candidates.size();++i) if(f.candidates[i]=="你好") index=int(i); } need(index>=0,"prefix candidate missing"); auto partial=h.key(keys[index]); need(partial.commit.empty() && partial.input=="nihaoshijie" && partial.preedit.find("你好")==0,"partial candidate prematurely committed or cleared"); need(partial.phase=="selecting" && !partial.candidates.empty() && partial.candidates[0]=="世界","remaining segment not normally selectable"); auto done=h.key(keys[0]); need(done.commit=="你好世界" && done.input.empty() && done.phase=="off","segmented sentence did not finish normally"); });
    test("ASCII_and_shortcut_passthrough",[&] { h.start(); api->set_option(h.sid,"ascii_mode",true); auto ascii=h.key('a',0,false); need(ascii.phase!="selecting" && ascii.input.empty(),"ASCII was intercepted"); auto f=h.arm(); auto ctrl=h.key(keys[0],4,false); need(!h.lastHandled && ctrl.commit.empty() && ctrl.input==f.input && ctrl.candidates==f.candidates,"Ctrl shortcut was consumed, selected or changed input"); });
    test("disable_restores_original_labels",[&] { h.start(); api->set_option(h.sid,"letter_selection_disabled",true); auto f=h.type("ni"); need(f.phase=="off" && !f.hidden && f.keys!=keys && !f.candidates.empty(),"disable did not restore native editing/labels"); auto expected=f.candidates[0]; auto done=h.key(32); need(done.commit==expected && done.input.empty(),"disabled Space did not restore native commit"); });
    test("independent_session_cleanup",[&] { h.arm(); h.start(); auto f=h.type("ni"); need(f.phase=="editing" && f.hidden==hide && f.keys!=keys,"selection state leaked into new session"); });
  } catch(const std::exception& e) { fatal=e.what(); ++failed; }
  std::ostringstream out;
  out << "{\"format\":1,\"kind\":\"real_librime_C_API_fixture\",\"status\":" << quote(failed?"FAIL":"PASS")
      << ",\"version\":" << quote(version) << ",\"keys\":" << quote(keys) << ",\"hide\":" << (hide?"true":"false")
      << ",\"page_size\":" << keys.size() << ",\"macOS_UI_tested\":false,\"network_calls\":0,\"user_dictionary_used\":false"
      << ",\"isolation_verified\":" << (fatal.empty() && !rows.empty()?"true":"false")
      << ",\"passed\":" << passed << ",\"failed\":" << failed << ",\"skipped\":" << skipped << ",\"fatal\":" << quote(fatal) << ",\"tests\":[";
  for(size_t i=0;i<rows.size();++i) { const auto& r=rows[i]; if(i) out << ',';
    out << "{\"name\":" << quote(r.name) << ",\"status\":" << quote(r.status) << ",\"error\":" << quote(r.error) << ",\"steps\":[";
    for(size_t n=0;n<r.steps.size();++n) { if(n) out << ','; out << r.steps[n]; } out << "]}";
  }
  out << "]}\n"; std::cout << out.str(); return failed?1:0;
}
#ifdef _WIN32
static std::string utf8(const wchar_t* s) {
  int size=WideCharToMultiByte(CP_UTF8,0,s,-1,nullptr,0,nullptr,nullptr);
  need(size>0,"cannot decode argument"); std::string result(size,'\0');
  WideCharToMultiByte(CP_UTF8,0,s,-1,result.data(),size,nullptr,nullptr); result.resize(size-1); return result;
}
int wmain(int argc,wchar_t** argv) {
  SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
  std::vector<std::string> args; for(int i=0;i<argc;++i) args.push_back(utf8(argv[i])); return run(args);
}
#else
int main(int argc,char** argv) { return run(std::vector<std::string>(argv,argv+argc)); }
#endif
