#include <jni.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
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
    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) return;

    char line[512];
    std::vector<std::tuple<void*, size_t, std::string>> to_hide;

    while (fgets(line, sizeof(line), maps)) {
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
                to_hide.emplace_back(reinterpret_cast<void*>(start),
                                    end - start,
                                    std::string(path_view));
                break;
            }
        }
    }
    fclose(maps);

    for (const auto &[addr, len, path] : to_hide) {
        void *backup = mmap(nullptr, len, PROT_READ | PROT_WRITE,
                           MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
        if (backup == MAP_FAILED) continue;

        int old_prot = GetProt(addr, len);
        bool prot_changed = false;

        if (!(old_prot & PROT_READ)) {
            if (mprotect(addr, len, old_prot | PROT_READ) != 0) {
                munmap(backup, len);
                continue;
            }
            prot_changed = true;
        }

        memcpy(backup, addr, len);
        void *result = mremap(backup, len, len, MREMAP_FIXED | MREMAP_MAYMOVE, addr);

        if (result != MAP_FAILED) {
            mprotect(addr, len, old_prot);
        } else {
            munmap(backup, len);
            if (prot_changed) {
                mprotect(addr, len, old_prot);
            }
        }
    }
}

static void PreloadFont(JNIEnv *env, const std::string &path) {
    static jclass typefaceClass = nullptr;
    static jmethodID methodId = nullptr;

    if (!typefaceClass) {
        jclass localClass = env->FindClass("android/graphics/Typeface");
        if (!localClass) {
            env->ExceptionClear();
            return;
        }
        typefaceClass = (jclass)env->NewGlobalRef(localClass);
        env->DeleteLocalRef(localClass);

        methodId = env->GetStaticMethodID(typefaceClass, "nativeWarmUpCache",
                                         "(Ljava/lang/String;)V");
        if (!methodId) {
            env->ExceptionClear();
            return;
        }
    }

    jstring jpath = env->NewStringUTF(path.c_str());
    if (!jpath) {
        env->ExceptionClear();
        return;
    }
    env->CallStaticVoidMethod(typefaceClass, methodId, jpath);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
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
    }

    void preAppSpecialize(AppSpecializeArgs *args) override {
        InitCompanion();

        for (const auto &rule : rules) {
            if (rule.classification == CLASS_FONT) {
                PreloadFont(env, rule.virtual_path);
            }
        }

        std::vector<std::string> paths_to_hide;
        for (const auto &rule : rules) {
            if (rule.hide_from_maps) {
                paths_to_hide.push_back(rule.virtual_path);
                paths_to_hide.push_back(rule.real_path);
            }
        }

        // Always hide common module paths
        paths_to_hide.push_back("/data/adb/modules");
        paths_to_hide.push_back("/data/adb/ksu");
        paths_to_hide.push_back("magisk");
        paths_to_hide.push_back("zygisk");

        HideFromMaps(paths_to_hide);

        api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
    }

    void preServerSpecialize(ServerSpecializeArgs *args) override {
        api->setOption(zygisk::Option::DLCLOSE_MODULE_LIBRARY);
    }

private:
    Api *api{};
    JNIEnv *env{};
    std::vector<Rule> rules;

    void InitCompanion() {
        int companion = api->connectCompanion();
        if (companion == -1) return;

        int count = read_int(companion);
        if (count < 0 || count > 10000) {
            close(companion);
            return;
        }

        for (int i = 0; i < count; i++) {
            Rule rule;

            int vpath_len = read_int(companion);
            if (vpath_len <= 0 || vpath_len >= 4096) {
                close(companion);
                return;
            }
            rule.virtual_path.resize(vpath_len);
            if (read_full(companion, rule.virtual_path.data(), vpath_len) != 0) {
                close(companion);
                return;
            }

            int rpath_len = read_int(companion);
            if (rpath_len <= 0 || rpath_len >= 4096) {
                close(companion);
                return;
            }
            rule.real_path.resize(rpath_len);
            if (read_full(companion, rule.real_path.data(), rpath_len) != 0) {
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

            rules.push_back(std::move(rule));
        }

        close(companion);
    }
};

static std::vector<Rule> g_rules;
static std::once_flag g_rules_init_flag;

static bool LoadRulesFromConfig() {
    const char *config_path = "/data/adb/nomount/rules.conf";

    std::ifstream file(config_path);
    if (!file.is_open()) {
        // Fallback: scan modules directly like FontLoader
        return false;
    }

    std::string line;
    while (std::getline(file, line)) {
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

        g_rules.push_back(std::move(rule));
    }

    return !g_rules.empty();
}

static bool ScanModulesForFonts() {
    DIR *modules_dir = opendir("/data/adb/modules");
    if (!modules_dir) return false;

    struct dirent *entry;
    char path[PATH_MAX];

    while ((entry = readdir(modules_dir))) {
        if (entry->d_type != DT_DIR || entry->d_name[0] == '.') continue;

        snprintf(path, PATH_MAX, "/data/adb/modules/%s/disable", entry->d_name);
        if (access(path, F_OK) == 0) continue;

        snprintf(path, PATH_MAX, "/data/adb/modules/%s/system/fonts", entry->d_name);
        if (access(path, F_OK) != 0) continue;

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
                g_rules.push_back(std::move(rule));
            }
        }
        closedir(fonts_dir);
    }
    closedir(modules_dir);

    return !g_rules.empty();
}

static void CompanionEntry(int socket) {
    std::call_once(g_rules_init_flag, []() {
        if (!LoadRulesFromConfig()) {
            ScanModulesForFonts();
        }
    });

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
}

REGISTER_ZYGISK_MODULE(HideMountModule)
REGISTER_ZYGISK_COMPANION(CompanionEntry)
