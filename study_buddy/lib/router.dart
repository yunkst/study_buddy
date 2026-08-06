import 'package:go_router/go_router.dart';
import 'features/external_qbank/external_qbank_page.dart';
import 'features/home/home_page.dart';

GoRouter buildRouter() {
  return GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const HomePage(),
      ),
      GoRoute(
        path: '/external-qbank',
        builder: (context, state) => const ExternalQbankPage(),
      ),
    ],
  );
}
