import 'package:flutter/material.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/log.dart';
import 'package:ffmpeg_kit_flutter_new/session.dart';
import 'package:ffmpeg_kit_flutter_new/statistics.dart';
import 'soure.dart';
import 'dart:io';
import 'package:video_player/video_player.dart';

/// MediaPage displays three tabs: My Videos, My Downloads, and My Favorites.
///
/// Previously this page required Face ID (or other biometrics) to unlock
/// sensitive content, but the lock has been removed. The tabs are now
/// always accessible without authentication.
class MediaPage extends StatefulWidget {
  const MediaPage({super.key});

  @override
  State<MediaPage> createState() => _MediaPageState();
}

class _MediaPageState extends State<MediaPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

  @override
  void initState() {
    super.initState();
    // Previously performed biometric authentication here. The app no longer
    // locks the media section behind Face ID/Touch ID.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('媒體'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [Tab(text: '我的影片'), Tab(text: '我的下載'), Tab(text: '我的收藏')],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        // Do not mark MyVideos and MyDownloads as const because they are stateful widgets
        children: const [_MyVideos(), _MyDownloads(), _MyFavorites()],
      ),
    );
  }
}

/// Placeholder for listing downloaded and encrypted videos stored in the app's sandbox.
class _MyVideos extends StatefulWidget {
  const _MyVideos();

  @override
  State<_MyVideos> createState() => _MyVideosState();
}

class _MyVideosState extends State<_MyVideos> {
  bool _selectMode = false;
  final Set<DownloadTask> _selected = {};

  void _toggleSelect(DownloadTask t) {
    setState(() {
      if (_selected.contains(t)) {
        _selected.remove(t);
      } else {
        _selected.add(t);
      }
    });
  }

  void _selectAll(List<DownloadTask> tasks) {
    setState(() {
      _selected
        ..clear()
        ..addAll(tasks);
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final repo = AppRepo.I;
    final toDelete = List<DownloadTask>.from(_selected);
    await repo.removeTasks(toDelete);
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
  }

  Future<void> _exportSelected() async {
    if (_selected.isEmpty) return;
    final repo = AppRepo.I;
    for (final t in _selected) {
      await repo.saveFileToGallery(t.savePath);
    }
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
  }

  void _renameTask(BuildContext context, DownloadTask t) {
    final controller = TextEditingController(text: t.name ?? '');
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('重新命名'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '輸入新的名稱'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  AppRepo.I.renameTask(t, name);
                }
                Navigator.pop(context);
              },
              child: const Text('確定'),
            ),
          ],
        );
      },
    );
  }

  void _playVideo(BuildContext context, DownloadTask t) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VideoPlayerPage(path: t.savePath, title: t.name ?? t.url),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Row(
            children: [
              if (_selectMode) ...[
                TextButton(
                  onPressed: () {
                    final list = repo.downloads.value
                        .where((d) => d.type == 'video' && d.state == 'done')
                        .toList();
                    _selectAll(list);
                  },
                  child: const Text('全選'),
                ),
                TextButton(
                  onPressed: _deleteSelected,
                  child: const Text('刪除'),
                ),
                TextButton(
                  onPressed: _exportSelected,
                  child: const Text('匯出'),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _selectMode = false;
                      _selected.clear();
                    });
                  },
                ),
              ] else ...[
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectMode = true;
                    });
                  },
                  child: const Text('選取'),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: repo.downloads,
            builder: (_, List<DownloadTask> list, __) {
              final videos = list
                  .where((t) => t.type == 'video' && t.state == 'done')
                  .toList();
              videos.sort((a, b) => b.timestamp.compareTo(a.timestamp));
              if (videos.isEmpty) {
                return const Center(child: Text('尚無影片'));
              }
              return ListView.separated(
                itemCount: videos.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = videos[i];
                  final selected = _selected.contains(t);
                  Widget leadingWidget;
                  if (t.thumbnailPath != null && File(t.thumbnailPath!).existsSync()) {
                    leadingWidget = ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.file(
                        File(t.thumbnailPath!),
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                      ),
                    );
                  } else {
                    leadingWidget = const Icon(Icons.ondemand_video);
                  }
                  return ListTile(
                    leading: _selectMode
                        ? Checkbox(
                            value: selected,
                            onChanged: (_) => _toggleSelect(t),
                          )
                        : leadingWidget,
                    title: Text(
                      t.name ?? t.url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('時間: ${t.timestamp.toLocal().toString().split('.')[0]}'),
                    trailing: _selectMode
                        ? null
                        : Wrap(
                            spacing: 4,
                            children: [
                              IconButton(
                                icon: Icon(t.favorite ? Icons.favorite : Icons.favorite_border),
                                tooltip: t.favorite ? '取消收藏' : '收藏',
                                onPressed: () => repo.setFavorite(t, !t.favorite),
                              ),
                              IconButton(
                                icon: const Icon(Icons.drive_file_rename_outline),
                                tooltip: '重新命名',
                                onPressed: () => _renameTask(context, t),
                              ),
                              IconButton(
                                icon: const Icon(Icons.share),
                                tooltip: '分享',
                                onPressed: () => repo.shareFile(t.savePath),
                              ),
                            ],
                          ),
                    onTap: () {
                      if (_selectMode) {
                        _toggleSelect(t);
                      } else {
                        _playVideo(context, t);
                      }
                    },
                    onLongPress: () {
                      if (!_selectMode) {
                        setState(() {
                          _selectMode = true;
                          _selected.add(t);
                        });
                      }
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Shows ongoing and completed download tasks with progress indicators and sharing options.
class _MyDownloads extends StatefulWidget {
  const _MyDownloads();

  @override
  State<_MyDownloads> createState() => _MyDownloadsState();
}

class _MyDownloadsState extends State<_MyDownloads> {
  bool _selectMode = false;
  final Set<DownloadTask> _selected = {};

  void _toggleSelect(DownloadTask t) {
    setState(() {
      if (_selected.contains(t)) {
        _selected.remove(t);
      } else {
        _selected.add(t);
      }
    });
  }

  void _selectAll(List<DownloadTask> tasks) {
    setState(() {
      _selected
        ..clear()
        ..addAll(tasks);
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final repo = AppRepo.I;
    final toDelete = List<DownloadTask>.from(_selected);
    await repo.removeTasks(toDelete);
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
  }

  Future<void> _saveSelected() async {
    if (_selected.isEmpty) return;
    final repo = AppRepo.I;
    for (final t in _selected) {
      await repo.saveFileToGallery(t.savePath);
    }
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
  }

  void _renameTask(BuildContext context, DownloadTask t) {
    final controller = TextEditingController(text: t.name ?? '');
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: const Text('重新命名'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '輸入新的名稱'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  AppRepo.I.renameTask(t, name);
                }
                Navigator.pop(context);
              },
              child: const Text('確定'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return Column(
      children: [
        // Top bar for selection actions
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Row(
            children: [
              if (_selectMode) ...[
                TextButton(
                  onPressed: () {
                    final list = repo.downloads.value;
                    _selectAll(list);
                  },
                  child: const Text('全選'),
                ),
                TextButton(
                  onPressed: _deleteSelected,
                  child: const Text('刪除'),
                ),
                TextButton(
                  onPressed: _saveSelected,
                  child: const Text('存相簿'),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _selectMode = false;
                      _selected.clear();
                    });
                  },
                ),
              ] else ...[
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectMode = true;
                    });
                  },
                  child: const Text('選取'),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: repo.downloads,
            builder: (_, List<DownloadTask> list, __) {
              // Sort by timestamp descending (latest first)
              final tasks = [...list]..sort((a, b) => b.timestamp.compareTo(a.timestamp));
              if (tasks.isEmpty) {
                return const Center(child: Text('尚無下載'));
              }
              return ListView.separated(
                itemCount: tasks.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final t = tasks[i];
                  final selected = _selected.contains(t);
                  final prog = (t.total == null || t.total == 0)
                      ? null
                      : t.received / (t.total!);
                  Widget leadingWidget;
                  if (t.thumbnailPath != null && File(t.thumbnailPath!).existsSync()) {
                    leadingWidget = ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.file(
                        File(t.thumbnailPath!),
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                      ),
                    );
                  } else if (t.type == 'video') {
                    leadingWidget = const Icon(Icons.ondemand_video);
                  } else if (t.type == 'audio') {
                    leadingWidget = const Icon(Icons.audiotrack);
                  } else {
                    leadingWidget = const Icon(Icons.file_download_outlined);
                  }
                  return ListTile(
                    leading: _selectMode
                        ? Checkbox(
                            value: selected,
                            onChanged: (_) => _toggleSelect(t),
                          )
                        : leadingWidget,
                    title: Text(
                      t.name ?? t.url,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('狀態: ${t.state}'),
                        Text('時間: ${t.timestamp.toLocal().toString().split('.')[0]}'),
                        if (prog != null) LinearProgressIndicator(value: prog),
                      ],
                    ),
                    trailing: _selectMode
                        ? null
                        : Wrap(
                            spacing: 4,
                            children: [
                              IconButton(
                                icon: Icon(t.favorite ? Icons.favorite : Icons.favorite_border),
                                tooltip: t.favorite ? '取消收藏' : '收藏',
                                onPressed: () => repo.setFavorite(t, !t.favorite),
                              ),
                              IconButton(
                                icon: const Icon(Icons.drive_file_rename_outline),
                                tooltip: '重新命名',
                                onPressed: () => _renameTask(context, t),
                              ),
                              IconButton(
                                icon: const Icon(Icons.share),
                                tooltip: '分享',
                                onPressed: () => repo.shareFile(t.savePath),
                              ),
                            ],
                          ),
                    onTap: () {
                      if (_selectMode) {
                        _toggleSelect(t);
                      }
                    },
                    onLongPress: () {
                      if (!_selectMode) {
                        setState(() {
                          _selectMode = true;
                          _selected.add(t);
                        });
                      }
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Lists favorite media URLs. Allows removal of favorites.
class _MyFavorites extends StatelessWidget {
  const _MyFavorites();

  @override
  Widget build(BuildContext context) {
    final repo = AppRepo.I;
    return ValueListenableBuilder(
      valueListenable: repo.downloads,
      builder: (_, List<DownloadTask> list, __) {
        final favs = list.where((t) => t.favorite).toList();
        favs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        if (favs.isEmpty) {
          return const Center(child: Text('尚無收藏'));
        }
        return ListView.separated(
          itemCount: favs.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final t = favs[i];
            Widget leadingWidget;
            if (t.thumbnailPath != null && File(t.thumbnailPath!).existsSync()) {
              leadingWidget = ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.file(
                  File(t.thumbnailPath!),
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                ),
              );
            } else if (t.type == 'video') {
              leadingWidget = const Icon(Icons.ondemand_video);
            } else if (t.type == 'audio') {
              leadingWidget = const Icon(Icons.audiotrack);
            } else {
              leadingWidget = const Icon(Icons.insert_drive_file);
            }
            return ListTile(
              leading: leadingWidget,
              title: Text(t.name ?? t.url, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('時間: ${t.timestamp.toLocal().toString().split('.')[0]}'),
              trailing: Wrap(
                spacing: 4,
                children: [
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '取消收藏',
                    onPressed: () => repo.setFavorite(t, false),
                  ),
                  IconButton(
                    icon: const Icon(Icons.drive_file_rename_outline),
                    tooltip: '重新命名',
                    onPressed: () {
                      final controller = TextEditingController(text: t.name ?? '');
                      showDialog(
                        context: context,
                        builder: (_) {
                          return AlertDialog(
                            title: const Text('重新命名'),
                            content: TextField(
                              controller: controller,
                              autofocus: true,
                              decoration: const InputDecoration(hintText: '輸入新的名稱'),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('取消'),
                              ),
                              TextButton(
                                onPressed: () {
                                  final name = controller.text.trim();
                                  if (name.isNotEmpty) {
                                    repo.renameTask(t, name);
                                  }
                                  Navigator.pop(context);
                                },
                                child: const Text('確定'),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.share),
                    tooltip: '分享',
                    onPressed: () => repo.shareFile(t.savePath),
                  ),
                ],
              ),
              onTap: () {
                if (t.type == 'video') {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => VideoPlayerPage(
                        path: t.savePath,
                        title: t.name ?? t.url,
                      ),
                    ),
                  );
                } else {
                  // For non-video files, default to sharing.
                  repo.shareFile(t.savePath);
                }
              },
            );
          },
        );
      },
    );
  }
}

/// A simple page for playing a downloaded video using [VideoPlayer].
class VideoPlayerPage extends StatefulWidget {
  final String path;
  final String title;
  const VideoPlayerPage({super.key, required this.path, required this.title});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late VideoPlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path))
      ..initialize().then((_) {
        setState(() {});
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: _controller.value.isInitialized
            ? AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              )
            : const CircularProgressIndicator(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          setState(() {
            _controller.value.isPlaying ? _controller.pause() : _controller.play();
          });
        },
        child: Icon(
          _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
        ),
      ),
    );
  }
}
