import 'package:flutter/material.dart';

import '../platform/integrations.dart';
import 'widgets.dart';

class AppPicker extends StatefulWidget {
  const AppPicker({super.key, required this.integrations, required this.touch});
  final PlatformIntegrations integrations;
  final VoidCallback touch;
  @override
  State<AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<AppPicker> {
  late final apps = widget.integrations.installedApps();
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: dialogTitle('Choose an installed app', Icons.apps),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: search,
              decoration: const InputDecoration(
                labelText: 'Search apps',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) {
                widget.touch();
                setState(() {});
              },
            ),
          ),
          Expanded(
            child: FutureBuilder<List<InstalledApp>>(
              future: apps,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Text(
                      'Could not load installed apps. Rebuild the Android app and retry.',
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final query = search.text.toLowerCase();
                final matches = snapshot.data!
                    .where((app) => app.name.toLowerCase().contains(query))
                    .toList();
                if (matches.isEmpty) {
                  return const Center(
                    child: Text('No matching installed apps.'),
                  );
                }
                return ListView.builder(
                  itemCount: matches.length,
                  itemBuilder: (context, index) {
                    final app = matches[index];
                    return ListTile(
                      leading: const Icon(Icons.android),
                      title: Text(app.name),
                      onTap: () {
                        widget.touch();
                        Navigator.pop(context, app);
                      },
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ),
        ],
      ),
    ),
  );
}
