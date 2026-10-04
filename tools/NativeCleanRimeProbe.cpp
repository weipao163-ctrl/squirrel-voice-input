// Verify the package's real default dictionaries in a NEW disposable data dir.
// No input-source registration, installed Rime data, audio, credentials or network.
#include "rime_api.h"
#include <dlfcn.h>
#include <filesystem>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>
namespace fs=std::filesystem;
static void need(bool ok,const char* message) { if(!ok) throw std::runtime_error(message); }
int main(int argc,char** argv) {
  RimeApi* api=nullptr; RimeSessionId sid=0;
  try {
    need(argc==4,"library, bundled SharedSupport and NEW data directory required");
    fs::path lib=argv[1],shared=argv[2],base=argv[3];
    need(lib.is_absolute() && shared.is_absolute() && base.is_absolute(),"absolute paths required");
    need(fs::is_regular_file(lib) && fs::is_directory(shared) && !fs::exists(base),"missing bundle or data dir already exists");
    fs::create_directories(base/"logs");
    auto module=dlopen(lib.c_str(),RTLD_NOW|RTLD_GLOBAL); need(module,"bundled librime failed to load");
    auto entry=reinterpret_cast<RimeApi*(*)()>(dlsym(module,"rime_get_api"));need(entry,"Rime entry missing");api=entry();
    std::string user=base.string(),log=(base/"logs").string(),share=shared.string();
    RimeTraits traits{};RIME_STRUCT_INIT(RimeTraits,traits);
    traits.shared_data_dir=share.c_str();traits.user_data_dir=user.c_str();traits.log_dir=log.c_str();
    traits.app_name="rime.enhanced_clean_probe";traits.distribution_code_name="clean-package-probe";
    api->setup(&traits);api->initialize(nullptr);
    need(api->start_maintenance(true),"fresh maintenance did not start");api->join_maintenance_thread();
    sid=api->create_session();need(sid,"fresh session failed");
    RimeSchemaList schemas{};need(api->get_schema_list(&schemas),"bundled enabled schemas unavailable");
    bool luna=false;auto count=schemas.size;std::vector<std::string> ids;
    for(size_t i=0;i<count;i++) { ids.push_back(schemas.list[i].schema_id);if(ids.back()=="luna_pinyin") luna=true; }
    api->free_schema_list(&schemas);need(luna,"fresh default pinyin missing");
    const std::map<std::string,std::string> fixture={
      {"luna_pinyin","zhongguo"},{"bopomofo","5j/"},{"cangjie5","a"},
      {"quick5","a"},{"stroke","h"},{"terra_pinyin","zhong-"}};
    for(const auto& id:ids) {
      need(fs::is_regular_file(shared/(id+".schema.yaml")),"enabled schema source missing from package");
      need(api->select_schema(sid,id.c_str()),"fresh enabled schema cannot be selected");
      auto query=fixture.find(id);need(query!=fixture.end(),"enabled schema lacks a candidate fixture");
      api->set_option(sid,"ascii_mode",false);
      for(char key:query->second) need(api->process_key(sid,key,0),"default schema fixture key rejected");
      RimeContext context{};RIME_STRUCT_INIT(RimeContext,context);
      need(api->get_context(sid,&context),"default schema fixture context unavailable");
      bool candidates=context.menu.num_candidates>0;api->free_context(&context);
      if(!candidates) throw std::runtime_error("default schema "+id+" has no real candidates");
      api->clear_composition(sid);
    }
    need(api->select_schema(sid,"quick5"),"bundled Quick5 missing");
    api->set_option(sid,"ascii_mode",false);need(api->process_key(sid,'a',0),"Quick5 key rejected");
    RimeContext quick{};RIME_STRUCT_INIT(RimeContext,quick);
    need(api->get_context(sid,&quick),"Quick5 context unavailable");
    bool quickCandidates=quick.menu.num_candidates>0;api->free_context(&quick);
    need(quickCandidates,"Quick5 dictionary has no real candidates");api->clear_composition(sid);
    need(api->select_schema(sid,"luna_pinyin"),"fresh default schema selection failed");
    api->set_option(sid,"ascii_mode",false);
    // Same Hans policy as the production frontend; this validates bundled
    // dictionaries/OpenCC, not IMK activation or the system input-source list.
    api->set_option(sid,"zh_hant",false);api->set_option(sid,"zh_hant_hk",false);
    api->set_option(sid,"zh_hant_tw",false);api->set_option(sid,"zh_hans",true);
    api->set_option(sid,"simplification",true);api->set_option(sid,"traditionalization",false);
    std::string output;
    for(const auto& item:{std::pair<const char*,const char*>{"zhongguo","中国"},{"ceshi","测试"}}) {
      for(const char* p=item.first;*p;p++) need(api->process_key(sid,*p,0),"fresh pinyin key rejected");
      need(api->process_key(sid,32,0),"fresh default Space rejected");
      RimeCommit commit{};RIME_STRUCT_INIT(RimeCommit,commit);need(api->get_commit(sid,&commit),"fresh default did not commit");
      std::string text=commit.text ? commit.text : "";api->free_commit(&commit);
      need(text==item.second,"fresh simplified default output mismatch");output+=text;
    }
    need(fs::is_regular_file(base/"build/luna_pinyin.table.bin"),"fresh dictionary build missing");
    api->destroy_session(sid);sid=0;api->finalize();api=nullptr;
    std::cout<<"{\"status\":\"PASS\",\"enabled_schemas\":"<<count<<",\"all_enabled_schema_sources_and_selection_verified\":true,\"all_enabled_schemas_have_real_candidates\":true,\"quick5_real_candidates\":true,\"empty_user_directory\":true,\"bundled_default_schema\":\"luna_pinyin\",\"simplified_fixture_output\":\""<<output<<"\",\"microphone_used\":false,\"cloud_calls\":0,\"input_source_registered\":false}\n";
    return 0;
  } catch(const std::exception& error) {
    if(api) { if(sid) api->destroy_session(sid);api->finalize(); }
    std::cerr<<error.what()<<'\n';return 1;
  }
}
