#include <cstdio>
#include <iomanip>
#include <sstream>
#include <string>
#include <vector>

// The CLI owns the OBJ parser, mode defaults, C ABI call and OBJ writer used
// by the desktop subprocess. Its main symbol is renamed at compile time.
int autoremesher_cli_main(int argc, char** argv);

extern "C" int vibe_remesh(int mode, int targetQuads, double adaptivity,
                            double sharpEdge) {
    if (mode < 0 || mode > 2) return 2;
    auto number = [](double value) {
        std::ostringstream stream;
        stream << std::setprecision(17) << value;
        return stream.str();
    };
    std::string target = std::to_string(targetQuads);
    std::string adaptive = number(adaptivity);
    std::string sharp = number(sharpEdge);
    const char* modeName[] = {"closed", "open-patch", "triangle"};
    std::vector<char*> args = {
        const_cast<char*>("autoremesher_cli"),
        const_cast<char*>("--input"), const_cast<char*>("/in.obj"),
        const_cast<char*>("--output"), const_cast<char*>("/out.obj"),
        const_cast<char*>("--mode"), const_cast<char*>(modeName[mode]),
        const_cast<char*>("--target-quads"), &target[0],
        const_cast<char*>("--adaptivity"), &adaptive[0],
        const_cast<char*>("--sharp-edge"), &sharp[0]
    };
    return autoremesher_cli_main(static_cast<int>(args.size()), args.data());
}
