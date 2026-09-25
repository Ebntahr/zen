// A C++17 program using the standard library, threads and exceptions.
// Build:  zig c++ -target riscv64-linux-musl -static -O2 hello.cpp -o hello-cpp
// In Zen: c++ hello.cpp -o hello-cpp
#include <algorithm>
#include <fstream>
#include <iostream>
#include <map>
#include <numeric>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

int main() {
    std::vector<int> v(10);
    std::iota(v.begin(), v.end(), 1);
    std::reverse(v.begin(), v.end());
    std::cout << "Hello from C++ on Zen OS!\nreversed:";
    for (int x : v) std::cout << ' ' << x;
    std::cout << "\nsum = " << std::accumulate(v.begin(), v.end(), 0) << '\n';

    std::map<std::string, int> words{{"zen", 3}, {"url", 3}, {"zig", 3}};
    for (auto &[w, n] : words) std::cout << w << " -> " << n << '\n';

    int total = 0;
    std::thread t([&] { for (int i = 1; i <= 100; ++i) total += i; });
    t.join();
    std::cout << "thread computed " << total << '\n';

    try {
        throw std::runtime_error("exceptions work");
    } catch (const std::exception &e) {
        std::cout << "caught: " << e.what() << '\n';
    }

    std::ifstream uname("sys:uname");
    std::string line;
    if (std::getline(uname, line)) std::cout << "sys:uname = " << line << '\n';
    return 0;
}
