// Development-only reference driver. MIT; upstream encoder included under its license.
#include "Luau/Parser.h"
#include "Luau/Common.h"
#include "Luau/Ast.h"
#include "Luau/Lexer.h"
#include "Luau/Compiler.h"
#include "Luau/BytecodeBuilder.h"
#include "lua.h"
#include "lualib.h"
#include <fstream>
#include <iostream>
#include <sstream>
#include <unordered_map>
#include <unordered_set>
#include <vector>
#include <cstring>
#include <iomanip>
LUAU_FASTFLAGVARIABLE(LuauExperimentalIfLocalAnalysis)
LUAU_FASTFLAGVARIABLE(LuauExperimentalWhileLocalAnalysis)
#include "AstJsonEncoder.cpp"
#ifndef LUAU_UPSTREAM_REVISION
#error "Build with the checksum-guarded CMake target"
#endif
static constexpr const char* revision = LUAU_UPSTREAM_REVISION;
static const std::unordered_set<std::string> kGrammarFlags = {
    "LuauSolverV2",
    "DebugLuauReportReturnTypeVariadicWithTypeSuffix",
    "LuauExportValueSyntax",
    "DebugLuauNoInline",
    "DebugLuauUserDefinedClasses",
    "LuauAllowGlobalDeclarationToBeCalledClass",
    "LuauSingleTypeOptionalPackReturnsAttributeParens",
    "LuauExperimentalIfLocalSyntax",
    "LuauExperimentalWhileLocalSyntax",
    "LuauDeclarationFixCrashOnBadUnicode",
};
static std::string toHex(const std::string& bytes) {
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (unsigned char b : bytes) out << std::setw(2) << unsigned(b);
    return out.str();
}
static void testLibraryConstantLookup(const char* library, const char* member, Luau::CompileConstant* constant) {
    if (std::strcmp(library, "vector") == 0) {
        if (std::strcmp(member, "zero") == 0) return Luau::setCompileConstantVector(constant, 0.0f, 0.0f, 0.0f, 0.0f);
        if (std::strcmp(member, "one") == 0) return Luau::setCompileConstantVector(constant, 1.0f, 1.0f, 1.0f, 0.0f);
    }
    if (std::strcmp(library, "Vector3") == 0) {
        if (std::strcmp(member, "one") == 0) return Luau::setCompileConstantVector(constant, 1.0f, 1.0f, 1.0f, 0.0f);
        if (std::strcmp(member, "xAxis") == 0) return Luau::setCompileConstantVector(constant, 1.0f, 0.0f, 0.0f, 0.0f);
    }
    if (std::strcmp(library, "test") == 0) {
        if (std::strcmp(member, "some_nil") == 0) return Luau::setCompileConstantNil(constant);
        if (std::strcmp(member, "some_boolean") == 0) return Luau::setCompileConstantBoolean(constant, true);
        if (std::strcmp(member, "some_number") == 0) return Luau::setCompileConstantNumber(constant, 4.75);
        if (std::strcmp(member, "some_string") == 0) return Luau::setCompileConstantString(constant, "test", 4);
    }
}
static std::vector<std::string>* gCapturedOutput = nullptr;
static int capturePrint(lua_State* L) {
    int n = lua_gettop(L);
    std::string line;
    for (int i = 1; i <= n; ++i) {
        size_t l = 0;
        const char* s = luaL_tolstring(L, i, &l);
        if (i > 1) line += '\t';
        line.append(s, l);
        lua_pop(L, 1);
    }
    if (gCapturedOutput) gCapturedOutput->push_back(line);
    return 0;
}
struct Encoder: Luau::AstJsonEncoder {
    bool visit(Luau::AstStatError* n) override {
        writeNode(n,"AstStatError",[&]{write("expressions",n->expressions);write("statements",n->statements);write("messageIndex",n->messageIndex);});return false;
    }
    bool visit(Luau::AstTypeError* n) override {
        writeNode(n,"AstTypeError",[&]{write("types",n->types);write("messageIndex",n->messageIndex);write("isMissing",n->isMissing);});return false;
    }

    bool visit(Luau::AstExprIfElse* n) override {
        writeNode(n,"AstExprIfElse",[&]{write("condition",n->condition);write("hasThen",n->hasThen);write("trueExpr",n->trueExpr);write("hasElse",n->hasElse);write("falseExpr",n->falseExpr);if(n->conditionLocal)write("conditionLocal",n->conditionLocal);});return false;
    }
    bool visit(Luau::AstStatWhile* n) override {
        writeNode(n,"AstStatWhile",[&]{write("condition",n->condition);write("body",n->body);write("hasDo",n->hasDo);if(n->conditionLocal)write("conditionLocal",n->conditionLocal);});return false;
    }
    bool visit(Luau::AstStatIf* n) override {
        writeNode(n,"AstStatIf",[&]{write("condition",n->condition);write("thenbody",n->thenbody);if(n->elsebody)write("elsebody",n->elsebody);write("hasThen",n->thenLocation.has_value());if(n->conditionLocal)write("conditionLocal",n->conditionLocal);});return false;
    }

    bool visit(Luau::AstStatDeclareGlobal* n) override {
        writeNode(n,"AstStatDeclareGlobal",[&]{write("name",n->name);write("nameLocation",n->nameLocation);write("luauType",n->type);});return false;
    }

    bool visit(Luau::AstStatTypeFunction* n) override {
        writeNode(n,"AstStatTypeFunction",[&]{write("name",n->name);write("nameLocation",n->nameLocation);write("body",n->body);write("exported",n->exported);write("hasErrors",n->hasErrors);});return false;
    }
    bool visit(Luau::AstExprInstantiate* n) override {
        writeNode(n,"AstExprInstantiate",[&]{write("expr",n->expr);write("typeArguments",n->typeArguments);});return false;
    }
    bool visit(Luau::AstStatClass* n) override {
        // Never silently drop experimental nodes absent from upstream AstJsonEncoder.
        writeNode(n,"AstStatClass",[&]{
            std::string_view modName = n->declModifier==Luau::AstStatClass::DeclModifier::Local ? "Local"
                : n->declModifier==Luau::AstStatClass::DeclModifier::Const ? "Const"
                : n->declModifier==Luau::AstStatClass::DeclModifier::Export ? "Export" : "None";
            write("declModifier",modName);
            if(n->declModifier==Luau::AstStatClass::DeclModifier::None)write("exprName",n->exprName);
            else write("localName",n->localName);
            if(n->super)write("super",n->super);
            write("open",n->open);
            writeRaw(",\"members\":[");bool first=true;
            for(auto& member:n->members){if(!first)writeRaw(',');first=false;writeRaw('{');bool saved=pushComma();
                if(auto p=Luau::get_if<Luau::AstClassProperty>(&member)){writeType("AstClassProperty");write("qualifierLocation",p->qualifierLocation);write("name",p->name);write("nameLocation",p->nameLocation);if(p->typeColonLocation)write("typeColonLocation",*p->typeColonLocation);if(p->ty)write("luauType",p->ty);else write("luauType",nullptr);write("access",std::string_view(p->access==Luau::AstClassAccess::Private?"Private":"Public"));}
                else if(auto m=Luau::get_if<Luau::AstClassMethod>(&member)){writeType("AstClassMethod");if(m->qualifierLocation)write("qualifierLocation",*m->qualifierLocation);write("keywordLocation",m->keywordLocation);write("functionName",m->functionName);write("nameLocation",m->nameLocation);if(m->function)write("function",m->function);else write("function",nullptr);write("access",std::string_view(m->access==Luau::AstClassAccess::Private?"Private":"Public"));}
                popComma(saved);writeRaw('}');
            }writeRaw(']');
        });return false;
    }
};
static std::string quote(const std::string& s) { Encoder e;e.write(s);return e.str(); }
static std::string quoteSafe(const std::string& s) {
    std::ostringstream out;
    out << '"';
    for (unsigned char c : s) {
        if (c == '"') out << "\\\"";
        else if (c == '\\') out << "\\\\";
        else if (c == '\n') out << "\\n";
        else if (c == '\r') out << "\\r";
        else if (c == '\t') out << "\\t";
        else if (c < 0x20 || c >= 0x7f) {
            char buf[8];
            std::snprintf(buf, sizeof(buf), "\\u%04x", unsigned(c));
            out << buf;
        } else {
            out << char(c);
        }
    }
    out << '"';
    return out.str();
}
struct Positions {
    std::vector<size_t> lines{0};
    explicit Positions(const std::string& source){for(size_t i=0;i<source.size();++i)if(source[i]=='\n')lines.push_back(i+1);}
    size_t at(Luau::Position p)const{return p.line<lines.size()?lines[p.line]+p.column:0;}
    std::string span(Luau::Location l)const{return "\"start\":"+std::to_string(at(l.begin))+",\"finish\":"+std::to_string(at(l.end));}
};
struct Bindings: Luau::AstVisitor {
    std::vector<Luau::AstLocal*> locals;
    std::unordered_map<Luau::AstLocal*,size_t> ids;
    struct Ref {Luau::Location location;size_t id;bool upvalue;};
    std::vector<Ref> refs;
    size_t add(Luau::AstLocal* local){if(!local)return 0;auto found=ids.find(local);if(found!=ids.end())return found->second;size_t id=locals.size()+1;ids[local]=id;locals.push_back(local);add(local->shadow);return id;}
    bool visit(Luau::AstStatIf* n)override{add(n->conditionLocal);return true;}
    bool visit(Luau::AstStatWhile* n)override{add(n->conditionLocal);return true;}
    bool visit(Luau::AstExprIfElse* n)override{add(n->conditionLocal);return true;}
    bool visit(Luau::AstStatLocal* n)override{for(auto x:n->vars)add(x);return true;}
    bool visit(Luau::AstStatLocalFunction* n)override{add(n->name);return true;}
    bool visit(Luau::AstStatFor* n)override{add(n->var);return true;}
    bool visit(Luau::AstStatForIn* n)override{for(auto x:n->vars)add(x);return true;}
    bool visit(Luau::AstExprFunction* n)override{add(n->self);for(auto x:n->args)add(x);return true;}
    bool visit(Luau::AstExprLocal* n)override{refs.push_back({n->location,add(n->local),n->upvalue});return true;}
    bool visit(Luau::AstStatClass* n)override{if(n->declModifier!=Luau::AstStatClass::DeclModifier::None)add(n->localName);return true;}
};
struct Sidebands: Luau::AstVisitor {
    bool visit(Luau::AstType*)override{return true;}
    bool visit(Luau::AstTypePack*)override{return true;}
    struct ErrorNode{Luau::Location location;const char* kind;unsigned index;};
    std::vector<ErrorNode> errorNodes;
    bool visit(Luau::AstExprError* n)override{errorNodes.push_back({n->location,"AstExprError",n->messageIndex});return true;}
    bool visit(Luau::AstStatError* n)override{errorNodes.push_back({n->location,"AstStatError",n->messageIndex});return true;}
    bool visit(Luau::AstTypeError* n)override{errorNodes.push_back({n->location,"AstTypeError",n->messageIndex});return true;}
};
static int runCompileMode(const std::string& source,const std::string& bytecode,uint32_t dumpFlags,const Luau::CompileOptions& copts,const Luau::ParseOptions& options){
    Luau::BytecodeBuilder bcb;bcb.setDumpFlags(dumpFlags);bcb.setDumpSource(source);
    std::string status="ok",errMsg,dump,remarks,typeInfo;std::vector<std::string> funcDumps;
    try{
        Luau::compileOrThrow(bcb,source,copts,options);
        dump=bcb.dumpEverything();remarks=bcb.dumpSourceRemarks();typeInfo=bcb.dumpTypeInfo();
        for(uint32_t i=0;i<bcb.getFunctionCount();++i)funcDumps.push_back(bcb.dumpFunction(i));
    }catch(const Luau::ParseErrors& e){status="parseError";errMsg=e.what();}catch(const Luau::CompileError& e){status="compileError";errMsg=e.what();}
    std::cout<<",\"status\":"<<quoteSafe(status)<<",\"bytecodeHex\":"<<quoteSafe(toHex(bytecode))<<",\"error\":"<<quoteSafe(errMsg)<<",\"dump\":"<<quoteSafe(dump)<<",\"remarks\":"<<quoteSafe(remarks)<<",\"typeInfo\":"<<quoteSafe(typeInfo)<<",\"functions\":[";
    for(size_t i=0;i<funcDumps.size();++i){if(i)std::cout<<',';std::cout<<quoteSafe(funcDumps[i]);}
    std::cout<<"]}\n";return 0;
}
static int runVmMode(const std::string& bytecode){
    lua_State* L=luaL_newstate();luaL_openlibs(L);
    std::vector<std::string> outLines;gCapturedOutput=&outLines;
    lua_pushcfunction(L,capturePrint,"print");lua_setglobal(L,"print");
    luaL_sandbox(L);luaL_sandboxthread(L);
    int loadRes=luau_load(L,"=chunk",bytecode.data(),bytecode.size(),0);
    std::string vmStatus="ok",vmError;std::vector<std::string> results;
    if(loadRes!=0){vmStatus="loadError";vmError=lua_tostring(L,-1)?lua_tostring(L,-1):"load error";}
    else{
        int callRes=lua_pcall(L,0,LUA_MULTRET,0);
        if(callRes!=0){vmStatus="runtimeError";vmError=lua_tostring(L,-1)?lua_tostring(L,-1):"runtime error";}
        else{int nret=lua_gettop(L);for(int i=1;i<=nret;++i){size_t l=0;const char* s=luaL_tolstring(L,i,&l);results.emplace_back(s,l);lua_pop(L,1);}}
    }
    gCapturedOutput=nullptr;lua_close(L);
    std::cout<<",\"status\":"<<quoteSafe(vmStatus)<<",\"error\":"<<quoteSafe(vmError)<<",\"output\":[";
    for(size_t i=0;i<outLines.size();++i){if(i)std::cout<<',';std::cout<<quoteSafe(outLines[i]);}
    std::cout<<"],\"results\":[";
    for(size_t i=0;i<results.size();++i){if(i)std::cout<<',';std::cout<<quoteSafe(results[i]);}
    std::cout<<"]}\n";return 0;
}
int main(int argc,char** argv){
    std::string profile="upstream",file="-",mode="chunk";bool lex=false;bool compileMode=false;bool vmMode=false;bool declarationOverride=false;
    int optLevel=1,debugLevel=1,typeInfoLevel=0,coverageLevel=0,vectorPrecision=0;
    uint32_t dumpFlags=Luau::BytecodeBuilder::Dump_Code|Luau::BytecodeBuilder::Dump_Lines|Luau::BytecodeBuilder::Dump_Locals|Luau::BytecodeBuilder::Dump_Remarks|Luau::BytecodeBuilder::Dump_Types|Luau::BytecodeBuilder::Dump_Constants;
    std::string vectorLib,vectorCtor,vectorType;
    bool testLibConstants=false;
    std::vector<std::string> overrides,intOverrides,mutableGlobals,userdataTypes,disabledBuiltins;
    for(int i=1;i<argc;++i){
        std::string a=argv[i];
        if(a=="--profile"&&i+1<argc)profile=argv[++i];
        else if(a=="--mode"&&i+1<argc)mode=argv[++i];
        else if(a=="--lex")lex=true;
        else if(a=="--compile")compileMode=true;
        else if(a=="--vm")vmMode=true;
        else if(a=="--declarations")declarationOverride=true;
        else if(a=="--opt"&&i+1<argc)optLevel=std::stoi(argv[++i]);
        else if(a=="--debug"&&i+1<argc)debugLevel=std::stoi(argv[++i]);
        else if(a=="--type-info"&&i+1<argc)typeInfoLevel=std::stoi(argv[++i]);
        else if(a=="--coverage"&&i+1<argc)coverageLevel=std::stoi(argv[++i]);
        else if(a=="--dump"&&i+1<argc)dumpFlags=uint32_t(std::stoul(argv[++i]));
        else if(a=="--vector-lib"&&i+1<argc)vectorLib=argv[++i];
        else if(a=="--vector-ctor"&&i+1<argc)vectorCtor=argv[++i];
        else if(a=="--vector-type"&&i+1<argc)vectorType=argv[++i];
        else if(a=="--vector-precision"&&i+1<argc)vectorPrecision=std::stoi(argv[++i]);
        else if(a=="--mutable-global"&&i+1<argc)mutableGlobals.push_back(argv[++i]);
        else if(a=="--userdata-type"&&i+1<argc)userdataTypes.push_back(argv[++i]);
        else if(a=="--disabled-builtin"&&i+1<argc)disabledBuiltins.push_back(argv[++i]);
        else if(a=="--test-lib-constants")testLibConstants=true;
        else if(a=="--flag"&&i+1<argc)overrides.push_back(argv[++i]);
        else if(a=="--int"&&i+1<argc)intOverrides.push_back(argv[++i]);
        else file=a;
    }
    if(profile!="upstream"&&profile!="studio"&&profile!="experimental"){std::cerr<<"unknown profile\n";return 2;}
    for(auto f=Luau::FValue<bool>::list;f;f=f->next)if(profile=="experimental"&&(kGrammarFlags.count(f->name)||std::strcmp(f->name,"LuauExperimentalIfLocalAnalysis")==0||std::strcmp(f->name,"LuauExperimentalWhileLocalAnalysis")==0))f->value=true;
    if(profile=="studio")for(auto f=Luau::FValue<bool>::list;f;f=f->next)if(std::strcmp(f->name,"LuauSolverV2")==0||std::strcmp(f->name,"LuauSingleTypeOptionalPackReturnsAttributeParens")==0||std::strcmp(f->name,"LuauAllowGlobalDeclarationToBeCalledClass")==0)f->value=true;
    // Studio grammar profile requires separate engine validation.
    for(auto& override:overrides){auto equals=override.find('=');if(equals==std::string::npos){std::cerr<<"expected --flag NAME=true|false\n";return 2;}auto name=override.substr(0,equals),value=override.substr(equals+1);bool found=false;for(auto f=Luau::FValue<bool>::list;f;f=f->next)if(name==f->name){f->value=value=="true";found=true;}if(!found||(value!="true"&&value!="false")){std::cerr<<"invalid flag override\n";return 2;}}
    for(auto& override:intOverrides){auto equals=override.find('=');if(equals==std::string::npos){std::cerr<<"expected --int NAME=VALUE\n";return 2;}auto name=override.substr(0,equals),value=override.substr(equals+1);bool found=false;for(auto f=Luau::FValue<int>::list;f;f=f->next)if(name==f->name){f->value=std::stoi(value);found=true;}if(!found){std::cerr<<"invalid int override\n";return 2;}}
    std::istream* input=&std::cin;std::ifstream disk;if(file!="-"){disk.open(file,std::ios::binary);if(!disk){std::cerr<<"cannot read "<<file<<"\n";return 2;}input=&disk;}
    std::string source((std::istreambuf_iterator<char>(*input)),{});Positions positions(source);
    Luau::Allocator allocator;Luau::AstNameTable names(allocator);
    std::cout<<"{\"revision\":"<<quote(revision)<<",\"profile\":"<<quote(profile)<<",\"flags\":{";bool comma=false;
    for(auto f=Luau::FValue<bool>::list;f;f=f->next){if(!kGrammarFlags.count(f->name)&&std::strcmp(f->name,"LuauExperimentalIfLocalAnalysis")!=0&&std::strcmp(f->name,"LuauExperimentalWhileLocalAnalysis")!=0)continue;if(comma)std::cout<<',';comma=true;std::cout<<quote(f->name)<<':'<<(f->value?"true":"false");}std::cout<<"}";
    if(lex){Luau::Lexer lexer(source.data(),source.size(),names);lexer.setSkipComments(false);std::cout<<",\"tokens\":[";comma=false;for(;;){auto t=lexer.next();if(comma)std::cout<<',';comma=true;std::cout<<"{\"kind\":"<<unsigned(t.type)<<','<<positions.span(t.location)<<'}';if(t.type==Luau::Lexeme::Eof)break;}std::cout<<"]}\n";return 0;}
    Luau::ParseOptions options;options.captureComments=true;options.allowDeclarationSyntax=declarationOverride;
    if(compileMode||vmMode){
        Luau::CompileOptions copts;
        copts.optimizationLevel=optLevel;
        copts.debugLevel=debugLevel;
        copts.typeInfoLevel=typeInfoLevel;
        copts.coverageLevel=coverageLevel;
        copts.vectorPrecision=vectorPrecision;
        if(!vectorLib.empty())copts.vectorLib=vectorLib.c_str();
        if(!vectorCtor.empty())copts.vectorCtor=vectorCtor.c_str();
        if(!vectorType.empty())copts.vectorType=vectorType.c_str();
        std::vector<const char*> mutPtrs,udataPtrs,disabledPtrs;
        if(!mutableGlobals.empty()){for(auto& s:mutableGlobals)mutPtrs.push_back(s.c_str());mutPtrs.push_back(nullptr);copts.mutableGlobals=mutPtrs.data();}
        if(!userdataTypes.empty()){for(auto& s:userdataTypes)udataPtrs.push_back(s.c_str());udataPtrs.push_back(nullptr);copts.userdataTypes=udataPtrs.data();}
        if(!disabledBuiltins.empty()){for(auto& s:disabledBuiltins)disabledPtrs.push_back(s.c_str());disabledPtrs.push_back(nullptr);copts.disabledBuiltins=disabledPtrs.data();}
        static const char* kTestLibs[]={"vector","Vector3","test",nullptr};
        if(testLibConstants){copts.librariesWithKnownMembers=kTestLibs;copts.libraryMemberConstantCb=testLibraryConstantLookup;}
        std::string bytecode=Luau::compile(source,copts,options);
        if(compileMode)return runCompileMode(source,bytecode,dumpFlags,copts,options);
        if(vmMode)return runVmMode(bytecode);
    }
    Luau::AstNode* root=nullptr;
    std::vector<Luau::ParseError> errors;
    std::vector<Luau::Comment> comments;
    std::vector<Luau::HotComment> hotcomments;
    auto capture=[&](const auto& result){root=result.root;errors=result.errors;comments=result.commentLocations;hotcomments=result.hotcomments;};
    if(mode=="chunk")capture(Luau::Parser::parse(source.data(),source.size(),names,allocator,options));
    else if(mode=="expression")capture(Luau::Parser::parseExpr(source.data(),source.size(),names,allocator,options));
    else if(mode=="type")capture(Luau::Parser::parseType(source.data(),source.size(),names,allocator,options));
    else{std::cerr<<"unknown mode\n";return 2;}
    Encoder e;if(root)root->visit(&e);else e.write(nullptr);
    std::cout<<",\"root\":"<<e.str()<<",\"diagnostics\":[";comma=false;
    for(auto& err:errors){if(comma)std::cout<<',';comma=true;std::cout<<'{'<<positions.span(err.getLocation())<<",\"message\":"<<quote(err.getMessage())<<'}';}
    std::cout<<"],\"comments\":[";comma=false;for(auto& c:comments){if(comma)std::cout<<',';comma=true;std::cout<<"{\"kind\":"<<unsigned(c.type)<<','<<positions.span(c.location)<<'}';}
    std::cout<<"],\"hotcomments\":[";comma=false;for(auto& c:hotcomments){if(comma)std::cout<<',';comma=true;std::cout<<"{\"header\":"<<(c.header?"true":"false")<<",\"content\":"<<quote(c.content)<<','<<positions.span(c.location)<<'}';}
    Bindings b;Sidebands sb;if(root){root->visit(&b);root->visit(&sb);}std::cout<<"],\"bindings\":[";comma=false;
    for(auto local:b.locals){if(comma)std::cout<<',';comma=true;std::cout<<"{\"id\":"<<b.ids[local]<<",\"name\":"<<quote(local->name.value)<<','<<positions.span(local->location)<<",\"shadow\":"<<(local->shadow?b.ids[local->shadow]:0)<<",\"functionDepth\":"<<local->functionDepth<<",\"loopDepth\":"<<local->loopDepth<<",\"isConst\":"<<(local->isConst?"true":"false")<<'}';}
    std::cout<<"],\"references\":[";comma=false;for(auto& r:b.refs){if(comma)std::cout<<',';comma=true;std::cout<<'{'<<positions.span(r.location)<<",\"binding\":"<<r.id<<",\"upvalue\":"<<(r.upvalue?"true":"false")<<'}';}std::cout<<"],\"errorNodes\":[";comma=false;for(auto& n:sb.errorNodes){if(comma)std::cout<<',';comma=true;std::cout<<'{'<<positions.span(n.location)<<",\"kind\":"<<quote(n.kind)<<",\"messageIndex\":"<<n.index<<'}';}std::cout<<"]}\n";return 0;
}
