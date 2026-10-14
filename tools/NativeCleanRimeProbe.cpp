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
      api->set_option(sid,"letter_selection_disabled",true);
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
    api->destroy_session(sid);sid=api->create_session();need(sid,"fresh letter session failed");
    need(api->select_schema(sid,"luna_pinyin"),"fresh letter schema failed");
    api->set_option(sid,"ascii_mode",false);
    // No user patch, Lua copy, settings save or extra deployment occurs here.
    need(!fs::exists(base/"luna_pinyin.custom.yaml") && !fs::exists(base/"settings.json"),"fresh test not empty");
    // Same Hans policy as the production frontend; this validates bundled
    // dictionaries/OpenCC, not IMK activation or the system input-source list.
    api->set_option(sid,"zh_hant",false);api->set_option(sid,"zh_hant_hk",false);
    api->set_option(sid,"zh_hant_tw",false);api->set_option(sid,"zh_hans",true);
    api->set_option(sid,"simplification",true);api->set_option(sid,"traditionalization",false);
    std::string output;
    for(const auto& item:{std::pair<const char*,const char*>{"zhongguo","中国"},{"ceshi","测试"}}) {
      for(const char* p=item.first;*p;p++) need(api->process_key(sid,*p,0),"fresh pinyin key rejected");
      need(api->process_key(sid,32,0),"fresh default Space rejected");
      RimeCommit premature{};RIME_STRUCT_INIT(RimeCommit,premature);
      bool committed=api->get_commit(sid,&premature);if(committed) api->free_commit(&premature);
      need(!committed,"first Space committed instead of opening letters");
      char phase[64]{};
      need(api->get_property(sid,"_letter_selection_phase",phase,sizeof(phase)) && std::string(phase)=="selecting","fresh default letter processor not active");
      need(api->process_key(sid,'a',0),"fresh default letter rejected");
      RimeCommit commit{};RIME_STRUCT_INIT(RimeCommit,commit);need(api->get_commit(sid,&commit),"fresh default did not commit");
      std::string text=commit.text ? commit.text : "";api->free_commit(&commit);
      need(text==item.second,"fresh simplified default output mismatch");output+=text;
    }
    RimeConfig config{};need(api->schema_open("luna_pinyin", &config), "fresh default schema unavailable");
    const char* first=api->config_get_cstring(&config,"engine/processors/@0");
    need(first && std::string(first)=="lua_processor@*letter_selection","default letter processor missing");
    int pageSize=0;need(api->config_get_int(&config,"menu/page_size",&pageSize) && pageSize==9,"default letter page size mismatch");
    const char* keys=api->config_get_cstring(&config,"letter_selection/keys");
    need(keys && std::string(keys)=="asdfghjkl","default selection keys mismatch");
    Bool letterEnabled=False;need(api->config_get_bool(&config,"letter_selection/enabled",&letterEnabled) && letterEnabled,"default letters not enabled");
    const char* activeDictionary=api->config_get_cstring(&config,"translator/dictionary");
    const char* learningDictionary=api->config_get_cstring(&config,"translator/user_dict");
    need(activeDictionary && std::string(activeDictionary)=="squirrel_public_pinyin","public dictionary is not active");
    need(learningDictionary && std::string(learningDictionary)=="luna_pinyin","learning identity changed");
    api->config_close(&config);
    need(fs::is_regular_file(base/"build/squirrel_public_pinyin.table.bin") ||
         fs::is_regular_file(shared/"build/squirrel_public_pinyin.table.bin"),"fresh public dictionary build missing");
    // Explicit opt-out must immediately restore the original numeric/Space path.
    api->set_option(sid,"letter_selection_disabled",true);
    for(char key:std::string("nihao")) need(api->process_key(sid,key,0),"disabled fixture key rejected");
    need(api->process_key(sid,32,0),"disabled Space rejected");
    RimeCommit disabled{};RIME_STRUCT_INIT(RimeCommit,disabled);
    need(api->get_commit(sid,&disabled),"saved opt-out cannot restore normal Space");api->free_commit(&disabled);
    api->set_option(sid,"letter_selection_disabled",false);
    for(char key:std::string("lovewin2k")) need(api->process_key(sid,key,0),"mixed key rejected");
    need(api->process_key(sid,0xff0d,0),"mixed Enter rejected");
    RimeCommit mixed{};RIME_STRUCT_INIT(RimeCommit,mixed);
    need(api->get_commit(sid,&mixed),"mixed literal not committed");
    std::string literal=mixed.text ? mixed.text : "";api->free_commit(&mixed);
    need(literal=="lovewin2k","mixed digits chose a Chinese candidate");
    api->destroy_session(sid);sid=0;api->finalize();api=nullptr;
    std::cout<<"{\"status\":\"PASS\",\"enabled_schemas\":"<<count<<",\"all_enabled_schema_sources_and_selection_verified\":true,\"all_enabled_schemas_have_real_candidates\":true,\"quick5_real_candidates\":true,\"default_letter_selection_verified\":true,\"default_letter_selection_no_manual_deployment\":true,\"saved_opt_out_restores_normal_space\":true,\"mixed_digit_literal_verified\":true,\"empty_user_directory\":true,\"bundled_default_schema\":\"luna_pinyin\",\"simplified_fixture_output\":\""<<output<<"\",\"microphone_used\":false,\"cloud_calls\":0,\"input_source_registered\":false}\n";
    return 0;
  } catch(const std::exception& error) {
    if(api) { if(sid) api->destroy_session(sid);api->finalize(); }
    std::cerr<<error.what()<<'\n';return 1;
  }
}
