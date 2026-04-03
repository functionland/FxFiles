#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console for the process, and redirects stdout and stderr to
// it for both the runner and the Flutter library.
void CreateAndAttachConsole();

// Takes a null-terminated wchar_t* encoded in UTF-16 and returns a std::string
// encoded in UTF-8. Returns an empty std::string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// Gets the command line arguments passed in as a std::vector<std::string>,
// encoded in UTF-8. Returns an empty std::vector<std::string> on failure.
std::vector<std::string> GetCommandLineArguments();

// Percent-encodes a UTF-8 string for use in URI query parameters (RFC 3986).
// All characters except unreserved (A-Z, a-z, 0-9, '-', '.', '_', '~') are encoded.
std::string UrlEncodeUtf8(const std::string& utf8_string);

#endif  // RUNNER_UTILS_H_
