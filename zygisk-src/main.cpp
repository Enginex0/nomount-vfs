#include <jni.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <vector>
#include <string>
#include <string_view>
#include <fstream>
#include <sstream>
#include <dirent.h>
#include "logging.h"
#include "zygisk.hpp"
#include "misc.h"

using zygisk::Api;
using zygisk::AppSpecializeArgs;
using zygisk::ServerSpecializeArgs;

enum Classification : uint8_t {
    CLASS_UNKNOWN = 0,
    CLASS_LIBRARY = 1,
    CLASS_FONT = 2,
    CLASS_MEDIA = 3,
    CLASS_APP = 4,
    CLASS_FRAMEWORK = 5,
    CLASS_CONFIG = 6,
};

struct Rule {
    std::string virtual_path;
    std::string real_path;
    Classification classification;
    bool hide_from_maps;
};

static int GetProt(void *addr, size_t len) {
    char line[512];
    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) return PROT_READ;

    uintptr_t target = reinterpret_cast<uintptr_t>(addr);
    int prot = 0;

    while (fgets(line, sizeof(line), maps)) {
        uintptr_t start, end;
        char perms[5];
        if (sscanf(line, "%lx-%lx %4s", &start, &end, perms) == 3) {
            if (target >= start && target < end) {
                if (perms[0] == 'r') prot |= PROT_READ;
                if (perms[1] == 'w') prot |= PROT_WRITE;
                if (perms[2] == 'x') prot |= PROT_EXEC;
                break;
            }
        }
    }
    fclose(maps);
    return prot ? prot : PROT_READ;
}

static void HideFromMaps(const std::vector<std::string> &paths) {
    LOGI("HideFromMaps: starting with %zu patterns", paths.size());

    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) {
        PLOGE("HideFromMaps: fopen /proc/self/maps");
        return;
    }

    char line[512];
    std::vector<std::tuple<void*, size_t, std::string>> to_hide;
    int lines_scanned = 0;

    while (fgets(line, sizeof(line), maps)) {
        lines_scanned++;
        uintptr_t start, end;
        char perms[5], pathname[256] = {0};

        int fields = sscanf(line, "%lx-%lx %4s %*s %*s %*s %255[^\n]",
                           &start, &end, perms, pathname);

        if (fields < 3 || start >= end) continue;

        std::string_view path_view(pathname);
        while (!path_view.empty() && path_view[0] == ' ')
            path_view.remove_prefix(1);

        for (const auto &hide_path : paths) {
            if (path_view.find(hide_path) != std::string_view::npos ||
                path_view.find("/data/adb/modules") != std::string_view::npos) {
                LOGD("HideFromMaps: match [%lx-%lx] %s", start, end, pathname);
                to_hide.emplace_back(reinterpret_cast<void*>(start),
                                    end - start,
                                    std::string(path_view));
                break;
            }
        }
    }
    fclose(maps);

    LOGI("HideFromMaps: scanned %d lines, found %zu to hide", lines_scanned, to_hide.size());

    int hidden_ok = 0, hidden_fail = 0;
    for (const auto &[addr, len, path] : to_hide) {
        void *backup = mmap(nullptr, len, PROT_READ | PROT_WRITE,
                           MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
        if (backup == MAP_FAILED) {
            PLOGE("HideFromMaps: mmap backup for %s", path.c_str());
            hidden_fail++;
            continue;
        }

        int old_prot = GetProt(addr, len);
        bool prot_changed = false;

        if (!(old_prot & PROT_READ)) {
            if (mprotect(addr, len, old_prot | PROT_READ) != 0) {
                PLOGE("HideFromMaps: mprotect for %s", path.c_str());
                munmap(backup, len);
                hidden_fail++;
                continue;
            }
            prot_changed = true;
        }

        memcpy(backup, addr, len);
        void *result = mremap(backup, len, len, MREMAP_FIXED | MREMAP_MAYMOVE, addr);

        if (result != MAP_FAILED) {
            mprotect(addr, len, old_prot);
            LOGD("HideFromMaps: OK %s", path.c_str());
            hidden_ok++;
        } else {
            PLOGE("HideFromMaps: mremap for %s", path.c_str());
            munmap(backup, len);
            if (prot_changed) {
                mprotect(addr, len, old_prot);
            }
            hidden_fail++;
        }
    }

    LOGI("HideFromMaps: done, hidden=%d failed=%d", hidden_ok, hidden_fail);
}

static void PreloadFont(JNIEnv *env, const std::string &path) {
    static jclass typefaceClass = nullptr;
    static jmethodID methodId = nullptr;

    LOGD("PreloadFont: %s", path.c_str());

    if (!typefaceClass) {
        jclass localClass = env->FindClass("android/graphics/Typeface");
        if (!localClass) {
            LOGE("PreloadFont: FindClass Typeface failed");
            env->ExceptionClear();
            return;
        }
        typefaceClass = (jclass)env->NewGlobalRef(localClass);
        env->DeleteLocalRef(localClass);

        methodId = env->GetStaticMethodID(typefaceClass, "nativeWarmUpCache",
                                         "(Ljava/lang/String;)V");
        if (!methodId) {
            LOGE("PreloadFont: GetStaticMethodID nativeWarmUpCache failed");
            env->ExceptionClear();
            return;
        }
        LOGI("PreloadFont: Typeface class initialized");
    }

    jstring jpath = env->NewStringUTF(path.c_str());
    if (!jpath) {
        LOGE("PreloadFont: NewStringUTF failed for %s", path.c_str());
        env->ExceptionClear();
        return;
    }
    env->CallStaticVoidMethod(typefaceClass, methodId, jpath);
    if (env->ExceptionCheck()) {
        LOGW("PreloadFont: exception for %s", path.c_str());
        env->ExceptionClear();
    } else {
        LOGD("PreloadFont: OK %s", path.c_str());
    }
    env->DeleteLocalRef(jpath);
}

static Classification ClassifyPath(const std::string &path) {
    if (path.find("/fonts/") != std::string::npos ||
        path.find(".ttf") != std::string::npos ||
        path.find(".otf") != std::string::npos) {
        return CLASS_FONT;
    }
    if (path.find(".so") != std::string::npos) {
        return CLASS_LIBRARY;
    }
    if (path.find("/framework/") != std::string::npos ||
        path.find(".jar") != std::string::npos ||
        path.find(".dex") != std::string::npos) {
        return CLASS_FRAMEWORK;
    }
    if (path.find("/media/") != std::string::npos ||
        path.find(".ogg") != std::string::npos ||
        path.find(".mp3") != std::string::npos) {
        return CLASS_MEDIA;
    }
    if (path.find(".apk") != std::string::npos) {
        return CLASS_APP;
    }
    if (path.find(".xml") != std::string::npos ||
        path.find(".conf") != std::string::npos ||
        path.find(".prop") != std::string::npos) {
        return CLASS_CONFIG;
    }
    return CLASS_UNKNOWN;
}

class HideMountModule : public zygisk::ModuleBase {
public:
    void onLoad(Api *_api, JNIEnv *_env) override {
        api = _api;
        env = _env;
        LOGI("onLoad: HideMount module loaded");
    }

    void preAppSpecialize(AppSpecializeArgs *args) override {
        const char *app_name = args->nice_name ? env->GetStringUTFChars(args->nice_name, nullptr) : "unknown";
        LOGI("preAppSpecialize: %s (uid=%d)", app_name, args->uid);
        if (args->nice_name) env->ReleaseStringUTFChars(args->nice_name, app_name);

        InitCompanion();

        // Kernel-only mode: skip all Zygisk work
        if (hiding_mode == 0) {
            LOGI("preAppSpecialize: kernel-only mode, skipping");
            api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
            return;
        }

        int fonts_preloaded = 0;
        for (const auto &rule : rules) {
            if (rule.classification == CLASS_FONT) {
                PreloadFont(env, rule.virtual_path);
                fonts_preloaded++;
            }
        }
        LOGI("preAppSpecialize: preloaded %d fonts", fonts_preloaded);

        std::vector<std::string> paths_to_hide;
        for (const auto &rule : rules) {
            if (rule.hide_from_maps) {
                paths_to_hide.push_back(rule.virtual_path);
                paths_to_hide.push_back(rule.real_path);
            }
        }

        paths_to_hide.push_back("/data/adb/modules");
        paths_to_hide.push_back("/data/adb/ksu");
        paths_to_hide.push_back("magisk");
        paths_to_hide.push_back("zygisk");

        HideFromMaps(paths_to_hide);

        api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
        LOGI("preAppSpecialize: done, requesting DLCLOSE");
    }

    void preServerSpecialize(ServerSpecializeArgs *args) override {
        LOGI("preServerSpecialize: system_server, skipping");
        api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
    }

private:
    Api *api{};
    JNIEnv *env{};
    std::vector<Rule> rules;
    int hiding_mode{1};

    void InitCompanion() {
        LOGD("InitCompanion: connecting...");
        int companion = api->connectCompanion();
        if (companion == -1) {
            LOGE("InitCompanion: connectCompanion failed");
            return;
        }

        // Read mode first
        hiding_mode = read_int(companion);
        LOGI("InitCompanion: hiding_mode=%d", hiding_mode);

        if (hiding_mode == 0) {
            // Kernel-only mode: skip reading rules
            read_int(companion);  // consume the 0 count
            close(companion);
            LOGI("InitCompanion: kernel-only mode, Zygisk work skipped");
            return;
        }

        int count = read_int(companion);
        if (count < 0 || count > 10000) {
            LOGE("InitCompanion: invalid count %d", count);
            close(companion);
            return;
        }
        LOGI("InitCompanion: receiving %d rules", count);

        for (int i = 0; i < count; i++) {
            Rule rule;

            int vpath_len = read_int(companion);
            if (vpath_len <= 0 || vpath_len >= 4096) {
                LOGE("InitCompanion: invalid vpath_len %d at rule %d", vpath_len, i);
                close(companion);
                return;
            }
            rule.virtual_path.resize(vpath_len);
            if (read_full(companion, rule.virtual_path.data(), vpath_len) != 0) {
                LOGE("InitCompanion: read vpath failed at rule %d", i);
                close(companion);
                return;
            }

            int rpath_len = read_int(companion);
            if (rpath_len <= 0 || rpath_len >= 4096) {
                LOGE("InitCompanion: invalid rpath_len %d at rule %d", rpath_len, i);
                close(companion);
                return;
            }
            rule.real_path.resize(rpath_len);
            if (read_full(companion, rule.real_path.data(), rpath_len) != 0) {
                LOGE("InitCompanion: read rpath failed at rule %d", i);
                close(companion);
                return;
            }

            int class_val = read_int(companion);
            if (class_val < 0 || class_val > CLASS_CONFIG) {
                rule.classification = CLASS_UNKNOWN;
            } else {
                rule.classification = static_cast<Classification>(class_val);
            }

            rule.hide_from_maps = (read_int(companion) != 0);

            LOGD("InitCompanion: rule[%d] vpath=%s class=%d hide=%d",
                 i, rule.virtual_path.c_str(), rule.classification, rule.hide_from_maps);
            rules.push_back(std::move(rule));
        }

        close(companion);
        LOGI("InitCompanion: loaded %zu rules", rules.size());
    }
};

static std::vector<Rule> g_rules;
static std::once_flag g_rules_init_flag;
static int g_hiding_mode = 1;  // 0=kernel-only, 1=hybrid (default)

static int LoadHidingMode() {
    const char *config_path = "/data/adb/nomount/config.sh";
    std::ifstream file(config_path);
    if (!file.is_open()) {
        LOGW("LoadHidingMode: config.sh not found, defaulting to hybrid mode");
        return 1;
    }

    std::string line;
    while (std::getline(file, line)) {
        if (line.find("hiding_mode=") == 0) {
            int mode = std::atoi(line.c_str() + 12);
            LOGI("LoadHidingMode: mode=%d", mode);
            return mode;
        }
    }

    LOGW("LoadHidingMode: hiding_mode not found, defaulting to hybrid");
    return 1;
}

static bool LoadRulesFromConfig() {
    const char *config_path = "/data/adb/nomount/rules.conf";

    LOGI("LoadRulesFromConfig: opening %s", config_path);
    std::ifstream file(config_path);
    if (!file.is_open()) {
        LOGW("LoadRulesFromConfig: file not found, will scan modules");
        return false;
    }

    std::string line;
    int line_num = 0;
    while (std::getline(file, line)) {
        line_num++;
        if (line.empty() || line[0] == '#') continue;

        std::istringstream iss(line);
        std::string type, vpath, rpath, flags, apps;

        if (!std::getline(iss, type, '|')) continue;
        if (!std::getline(iss, vpath, '|')) continue;
        std::getline(iss, rpath, '|');
        std::getline(iss, flags, '|');
        std::getline(iss, apps, '|');

        if (type != "FILE" && type != "DIR") continue;

        Rule rule;
        rule.virtual_path = vpath;
        rule.real_path = rpath;
        rule.classification = ClassifyPath(vpath);
        rule.hide_from_maps = (flags.find("MAPS") != std::string::npos);

        LOGD("LoadRulesFromConfig: [%d] %s -> %s (class=%d, hide=%d)",
             line_num, vpath.c_str(), rpath.c_str(), rule.classification, rule.hide_from_maps);
        g_rules.push_back(std::move(rule));
    }

    LOGI("LoadRulesFromConfig: loaded %zu rules from config", g_rules.size());
    return !g_rules.empty();
}

static bool ScanModulesForFonts() {
    LOGI("ScanModulesForFonts: scanning /data/adb/modules");
    DIR *modules_dir = opendir("/data/adb/modules");
    if (!modules_dir) {
        PLOGE("ScanModulesForFonts: opendir /data/adb/modules");
        return false;
    }

    struct dirent *entry;
    char path[PATH_MAX];
    int modules_checked = 0, fonts_found = 0;

    while ((entry = readdir(modules_dir))) {
        if (entry->d_type != DT_DIR || entry->d_name[0] == '.') continue;

        snprintf(path, PATH_MAX, "/data/adb/modules/%s/disable", entry->d_name);
        if (access(path, F_OK) == 0) {
            LOGD("ScanModulesForFonts: %s disabled, skipping", entry->d_name);
            continue;
        }

        snprintf(path, PATH_MAX, "/data/adb/modules/%s/system/fonts", entry->d_name);
        if (access(path, F_OK) != 0) continue;

        modules_checked++;
        LOGD("ScanModulesForFonts: checking %s", entry->d_name);

        DIR *fonts_dir = opendir(path);
        if (!fonts_dir) continue;

        struct dirent *font_entry;
        while ((font_entry = readdir(fonts_dir))) {
            if (font_entry->d_type != DT_REG || font_entry->d_name[0] == '.') continue;

            char vpath[PATH_MAX];
            snprintf(vpath, PATH_MAX, "/system/fonts/%s", font_entry->d_name);

            if (access(vpath, F_OK) == 0) {
                Rule rule;
                rule.virtual_path = vpath;
                rule.real_path = path;
                rule.real_path += "/";
                rule.real_path += font_entry->d_name;
                rule.classification = CLASS_FONT;
                rule.hide_from_maps = true;
                LOGD("ScanModulesForFonts: found %s", vpath);
                g_rules.push_back(std::move(rule));
                fonts_found++;
            }
        }
        closedir(fonts_dir);
    }
    closedir(modules_dir);

    LOGI("ScanModulesForFonts: checked %d modules, found %d fonts", modules_checked, fonts_found);
    return !g_rules.empty();
}

static void CompanionEntry(int socket) {
    LOGI("CompanionEntry: client connected (fd=%d)", socket);

    std::call_once(g_rules_init_flag, []() {
        LOGI("CompanionEntry: initializing (first client)");
        g_hiding_mode = LoadHidingMode();
        if (g_hiding_mode == 1) {
            if (!LoadRulesFromConfig()) {
                ScanModulesForFonts();
            }
            LOGI("CompanionEntry: hybrid mode, %zu rules loaded", g_rules.size());
        } else {
            LOGI("CompanionEntry: kernel-only mode, Zygisk disabled");
        }
    });

    // Send mode first
    write_int(socket, g_hiding_mode);

    if (g_hiding_mode == 0) {
        // Kernel-only mode: send 0 rules, client will skip all work
        write_int(socket, 0);
        close(socket);
        LOGD("CompanionEntry: kernel-only mode, sent 0 rules");
        return;
    }

    LOGD("CompanionEntry: sending %zu rules", g_rules.size());
    write_int(socket, g_rules.size());

    for (const auto &rule : g_rules) {
        write_int(socket, rule.virtual_path.size());
        write_full(socket, rule.virtual_path.data(), rule.virtual_path.size());

        write_int(socket, rule.real_path.size());
        write_full(socket, rule.real_path.data(), rule.real_path.size());

        write_int(socket, static_cast<int>(rule.classification));
        write_int(socket, rule.hide_from_maps ? 1 : 0);
    }

    close(socket);
    LOGD("CompanionEntry: done, socket closed");
}

REGISTER_ZYGISK_MODULE(HideMountModule)
REGISTER_ZYGISK_COMPANION(CompanionEntry)
