/// Test-only helper module that defines a role type *outside* of
/// `access_control_tests`'s home module. Its `TypeName` shares the package
/// address with `access_control_tests` but differs in `module_string`, which
/// is exactly the case the library's home-module check (`assert_home_module`)
/// rejects with `EForeignRole`.
module openzeppelin_access::foreign_role;

public struct ForeignRole {}
