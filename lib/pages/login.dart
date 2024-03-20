import 'package:adaptive_dialog/adaptive_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';

import '../buildcontext_extension.dart';
import '../models/db.dart';
import '../providers/settings.dart';
import '../services/remote_sync.dart';
import '../wallabag/credentials.dart';
import '../wallabag/utils.dart';
import '../wallabag/wallabag.dart';
import 'login_forms/server_form.dart';
import 'login_forms/validators.dart';

final _log = Logger('login');

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key, this.initial});

  final Map<String, String>? initial;

  bool get hasInitialData => initial != null && initial!.isNotEmpty;

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  late Map<String, String>? _initialData;
  final _serverFbKey = GlobalKey<FormBuilderState>();
  WallabagServerCheck? _configuredServer;
  final _fbKey = GlobalKey<FormBuilderState>();
  bool _gotAnError = false;

  @override
  void initState() {
    super.initState();

    final wallabag = WallabagInstance.get();
    if (!widget.hasInitialData && wallabag.hasCredentials) {
      _initialData = {
        'server': wallabag.credentials.server.toString(),
        'clientId': wallabag.credentials.clientId,
        'clientSecret': wallabag.credentials.clientSecret,
      };
    } else {
      _initialData = widget.initial;
    }

    if (WallabagInstance.isReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final settings = ref.read(settingsProvider);
        final result = await showOkCancelAlertDialog(
          context: context,
          title: context.L.login_existingSessionDialogTitle,
          message: context.L.login_existingSessionDialogMessage,
          okLabel: context.L.login_existingSessionDialogConfirm,
          isDestructiveAction: true,
        );
        if (result == OkCancelResult.ok) {
          await WallabagInstance.get().resetTokenData();
          settings.remove(Sk.lastRefresh);
          await DB.clear();
        } else {
          if (context.mounted) {
            context.go('/');
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hasInitialData && _initialData != widget.initial) {
      // when a deeplink is opened and the login page is already shown
      _initialData = widget.initial;
      if (_initialData?['server'] != null) {
        _serverFbKey.currentState?.fields['server']!
            .didChange(_initialData!['server']);
      }
      for (final key in ['clientId', 'clientSecret', 'username', 'password']) {
        if (_initialData?[key] != null) {
          _fbKey.currentState?.fields[key]!.didChange(_initialData![key]);
        }
      }
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.L.login_title)),
      body: ListView(
        children: [
          ServerForm(
            stateKey: _serverFbKey,
            onCheckChange: (check) => setState(() {
              if (check?.isValid ?? false) {
                _configuredServer = check;
              }
            }),
            initial: _initialData?['server'],
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Card(
              surfaceTintColor: Colors.transparent,
              elevation: 2,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(1.0)),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: FormBuilder(
                  key: _fbKey,
                  enabled: _configuredServer != null,
                  child: Column(children: [
                    FormBuilderTextField(
                      name: 'clientId',
                      validator: (value) => notEmptyValidator(
                          context, value, context.L.login_fieldClientId),
                      decoration: InputDecoration(
                        icon: const Icon(Icons.key),
                        labelText: context.L.login_fieldClientId,
                      ),
                      initialValue: _initialData?['clientId'],
                    ),
                    FormBuilderTextField(
                      name: 'clientSecret',
                      validator: (value) => notEmptyValidator(
                          context, value, context.L.login_fieldClientSecret),
                      decoration: InputDecoration(
                        icon: const Icon(Icons.key),
                        labelText: context.L.login_fieldClientSecret,
                      ),
                      initialValue: _initialData?['clientSecret'],
                    ),
                    FormBuilderTextField(
                      name: 'username',
                      autofillHints: const [AutofillHints.username],
                      validator: (value) => notEmptyValidator(
                          context, value, context.L.login_fieldUsername),
                      decoration: InputDecoration(
                        icon: const Icon(Icons.person),
                        labelText: context.L.login_fieldUsername,
                      ),
                      initialValue: _initialData?['username'],
                    ),
                    FormBuilderTextField(
                      name: 'password',
                      autofillHints: const [AutofillHints.password],
                      validator: (value) => notEmptyValidator(
                          context, value, context.L.login_fieldPassword),
                      obscureText: true, // TODO password visibility toggle
                      decoration: InputDecoration(
                        icon: const Icon(Icons.password),
                        labelText: context.L.login_fieldPassword,
                      ),
                      initialValue: _initialData?['password'],
                    ),
                    const SizedBox(height: 8.0),
                  ]),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8.0),
          ElevatedButton(
            onPressed: _configuredServer == null
                ? null
                : () async {
                    if (_fbKey.currentState!.saveAndValidate()) {
                      final credentials = Credentials(
                        _configuredServer!.uri!,
                        _fbKey.currentState!.value['clientId'],
                        _fbKey.currentState!.value['clientSecret'],
                      );
                      try {
                        final wallabag = await WallabagInstance.init(
                            credentials: credentials);
                        await wallabag.fetchToken(
                            _fbKey.currentState!.value['username'],
                            _fbKey.currentState!.value['password']);
                        RemoteSyncer.instance.invalidateWallabagInstance();
                        if (context.mounted) {
                          context.go('/');
                        }
                      } catch (e) {
                        setState(() => _gotAnError = true);
                        if (e is WallabagError) {
                          _log.warning('authentication failed', e.message);
                          if (context.mounted) {
                            showOkAlertDialog(
                                context: context, message: e.message);
                          }
                        } else {
                          _log.severe('unexpected error', e);
                          if (context.mounted) {
                            showOkAlertDialog(
                                context: context, message: e.toString());
                          }
                        }
                      }
                    }
                  },
            child: Text(context.L.login_actionLogin),
          ),
          const SizedBox(height: 8.0),
          if (_gotAnError)
            MaterialButton(
              onPressed: () => context.push('/logs'),
              child: Text(context.L.login_openLogConsole),
            ),
        ],
      ),
    );
  }
}
