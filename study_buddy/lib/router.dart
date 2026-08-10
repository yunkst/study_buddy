import 'package:go_router/go_router.dart';
import 'features/home/main_shell.dart';
import 'features/knowledge/topic_detail_page.dart';
import 'features/overlay/permission_guide_page.dart';

GoRouter buildRouter() {
  return GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => const MainShell()),
      GoRoute(
        path: '/permission-guide',
        builder: (context, state) => const PermissionGuidePage(),
      ),
      GoRoute(
        path: '/topic/:id',
        builder: (context, state) =>
            TopicDetailPage(topicId: int.parse(state.pathParameters['id']!)),
      ),
    ],
  );
}
