import 'package:go_router/go_router.dart';
import 'features/home/main_shell.dart';
import 'features/overlay/permission_guide_page.dart';

GoRouter buildRouter() {
  return GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const MainShell()),
      GoRoute(
        path: '/permission-guide',
        builder: (context, state) => const PermissionGuidePage(),
      ),
    ],
  );
}
