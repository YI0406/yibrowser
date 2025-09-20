import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:video_player/video_player.dart';

class MediaSegmentExportPage extends StatefulWidget {
  final String sourcePath;
  final String? displayName;
  final String mediaType;
  final Duration? initialDuration;

  const MediaSegmentExportPage({
    super.key,
    required this.sourcePath,
    this.displayName,
    this.mediaType = 'video',
    this.initialDuration,
  });

  @override
  State<MediaSegmentExportPage> createState() => _MediaSegmentExportPageState();
}

class _MediaSegmentExportPageState extends State<MediaSegmentExportPage> {
  static const double _kMinSelectableSeconds = 0.1;

  late final TextEditingController _nameController;
  late String _selectedFormat;
  late String _baseName;

  VideoPlayerController? _controller;
  bool _initializing = true;
  String? _loadError;
  String? _previewError;

  Duration _mediaDuration = Duration.zero;
  Duration _currentPosition = Duration.zero;
  double _durationSeconds = 0.0;
  RangeValues _selection = const RangeValues(0.0, 0.0);
  bool _selectionInitialized = false;
  bool _isPlaying = false;

  bool _processing = false;
  double? _progress;
  int? _activeSessionId;
  bool _cancelRequested = false;
  String? _lastOutputPath;

  String _lastSuggestedName = '';

  @override
  void initState() {
    super.initState();
    _selectedFormat = 'mp3';
    _baseName = _sanitizeFileName(
      widget.displayName != null && widget.displayName!.trim().isNotEmpty
          ? widget.displayName!
          : p.basenameWithoutExtension(widget.sourcePath),
    );
    if (_baseName.isEmpty) {
      _baseName = 'export';
    }
    _nameController = TextEditingController();
    _applyDuration(widget.initialDuration);
    _updateSuggestedFileName(force: true);
    _initializeController();
  }

  @override
  void dispose() {
    _controller?.removeListener(_handleControllerUpdate);
    _controller?.dispose();
    _nameController.dispose();
    final sessionId = _activeSessionId;
    if (sessionId != null) {
      () async {
        try {
          await FFmpegKit.cancel(sessionId);
        } catch (_) {}
      }();
    }
    super.dispose();
  }

  void _applyDuration(Duration? duration) {
    if (duration == null || duration <= Duration.zero) {
      return;
    }
    final seconds = duration.inMilliseconds / 1000.0;
    if (seconds <= 0) {
      return;
    }
    _mediaDuration = duration;
    _durationSeconds = seconds;
    if (!_selectionInitialized ||
        _selection.end <= 0 ||
        _selection.end > seconds) {
      _selection = RangeValues(0.0, seconds);
      _selectionInitialized = true;
    } else {
      final double start = _selection.start.clamp(0.0, seconds).toDouble();
      final double end = _selection.end.clamp(start, seconds).toDouble();
      _selection = RangeValues(start, end);
    }
  }

  Future<void> _initializeController() async {
    final file = File(widget.sourcePath);
    if (!await file.exists()) {
      setState(() {
        _loadError = '找不到來源檔案';
        _initializing = false;
      });
      return;
    }
    try {
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      controller.addListener(_handleControllerUpdate);
      controller.setLooping(false);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      _controller = controller;
      _applyDuration(controller.value.duration);
      setState(() {
        _initializing = false;
        _previewError = null;
      });
    } catch (e) {
      setState(() {
        _initializing = false;
        _previewError = '預覽無法載入: $e';
      });
    }
  }

  void _handleControllerUpdate() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    if (!mounted) return;
    final end = Duration(milliseconds: (_selection.end * 1000).round());
    final pos = value.position;
    final playing = value.isPlaying;
    if (playing &&
        end > Duration.zero &&
        pos >= end - const Duration(milliseconds: 20)) {
      controller.pause();
      controller.seekTo(end);
    }
    if ((pos - _currentPosition).abs() > const Duration(milliseconds: 150) ||
        playing != _isPlaying) {
      setState(() {
        _currentPosition = pos;
        _isPlaying = controller.value.isPlaying;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('編輯導出'),
        actions: [
          if (_processing && _activeSessionId != null)
            TextButton(
              onPressed: _cancelRequested ? null : _cancelExport,
              child: Text(
                _cancelRequested ? '取消中…' : '取消',
                style: const TextStyle(color: Colors.white),
              ),
            ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_initializing) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(child: Text(_loadError!));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                widget.mediaType == 'audio' ? Icons.audiotrack : Icons.movie,
              ),
              title: Text(
                widget.displayName?.trim().isNotEmpty == true
                    ? widget.displayName!
                    : p.basename(widget.sourcePath),
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(
                    '來源長度: ' +
                        (_durationSeconds > 0
                            ? _formatReadable(_mediaDuration)
                            : '未知'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '來源路徑: ${widget.sourcePath}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_previewError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _previewError!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          _buildPreviewSection(theme),
          const SizedBox(height: 24),
          _buildSelectionSection(theme),
          const SizedBox(height: 24),
          _buildFormatSection(theme),
          const SizedBox(height: 24),
          if (_processing) ...[
            LinearProgressIndicator(
              value: _progress != null ? _progress!.clamp(0.0, 1.0) : null,
            ),
            const SizedBox(height: 12),
          ],
          ElevatedButton.icon(
            onPressed: _processing ? null : _startExport,
            icon: const Icon(Icons.save_alt),
            label: Text(_processing ? '匯出中…' : '匯出選取的音訊'),
          ),
          const SizedBox(height: 16),
          if (_lastOutputPath != null)
            Card(
              child: ListTile(
                leading: const Icon(Icons.check_circle, color: Colors.green),
                title: const Text('最近匯出'),
                subtitle: Text(_lastOutputPath!),
                trailing: IconButton(
                  icon: const Icon(Icons.open_in_new),
                  tooltip: '開啟資料夾',
                  onPressed: () => _openOutputLocation(_lastOutputPath!),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPreviewSection(ThemeData theme) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Container(
        height: 200,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: theme.colorScheme.surfaceVariant,
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.music_note, size: 48),
            SizedBox(height: 8),
            Text('無法預覽，仍可進行匯出'),
          ],
        ),
      );
    }
    final aspect = controller.value.aspectRatio;
    final durationLabel = _formatReadable(_mediaDuration);
    final position = _currentPosition;
    final double sliderMax = _durationSeconds > 0 ? _durationSeconds : 1.0;
    final sliderValue = position.inMilliseconds / 1000.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(
            aspectRatio: aspect > 0 ? aspect : 16 / 9,
            child: VideoPlayer(controller),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(_formatReadable(position)),
            Expanded(
              child: Slider(
                value: sliderValue.clamp(0.0, sliderMax).toDouble(),
                min: 0.0,
                max: sliderMax,
                onChanged: (value) {
                  controller.seekTo(
                    Duration(milliseconds: (value * 1000).round()),
                  );
                  setState(() {
                    _currentPosition = Duration(
                      milliseconds: (value * 1000).round(),
                    );
                  });
                },
              ),
            ),
            Text(durationLabel),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.replay_10),
              tooltip: '倒退 10 秒',
              onPressed: () => _seekRelative(const Duration(seconds: -10)),
            ),
            IconButton(
              icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
              iconSize: 40,
              tooltip: _isPlaying ? '暫停' : '播放',
              onPressed: _togglePlayback,
            ),
            IconButton(
              icon: const Icon(Icons.forward_10),
              tooltip: '快轉 10 秒',
              onPressed: () => _seekRelative(const Duration(seconds: 10)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSelectionSection(ThemeData theme) {
    if (_durationSeconds <= 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [Text('無法取得媒體長度，請直接匯出整段。')],
      );
    }
    final selection = _selection;
    final start = selection.start;
    final end = selection.end;
    final labels = RangeLabels(
      _formatReadable(Duration(milliseconds: (start * 1000).round())),
      _formatReadable(Duration(milliseconds: (end * 1000).round())),
    );
    final clipSeconds = math.max(0.0, end - start);
    final clipDuration = Duration(milliseconds: (clipSeconds * 1000).round());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('選取範圍', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        RangeSlider(
          values: selection,
          min: 0.0,
          max: _durationSeconds,
          labels: labels,
          onChanged: (values) {
            setState(() {
              _selection = RangeValues(
                values.start.clamp(0.0, _durationSeconds).toDouble(),
                values.end.clamp(0.0, _durationSeconds).toDouble(),
              );
            });
          },
        ),
        Text(
          '起點：${_formatReadable(Duration(milliseconds: (start * 1000).round()))}',
        ),
        Text(
          '終點：${_formatReadable(Duration(milliseconds: (end * 1000).round()))}',
        ),
        Text(
          '長度：${_formatReadable(clipDuration)} (${clipSeconds.toStringAsFixed(2)} 秒)',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _setStartFromCurrent,
              icon: const Icon(Icons.flag),
              label: const Text('以目前時間為起點'),
            ),
            OutlinedButton.icon(
              onPressed: _setEndFromCurrent,
              icon: const Icon(Icons.outlined_flag),
              label: const Text('以目前時間為終點'),
            ),
            OutlinedButton.icon(
              onPressed: _previewSelection,
              icon: const Icon(Icons.play_circle_fill),
              label: const Text('預覽選取範圍'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFormatSection(ThemeData theme) {
    final formats = <String>['mp3', 'm4a', 'aac', 'wav'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('輸出設定', style: theme.textTheme.titleMedium),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: _selectedFormat,
          items:
              formats
                  .map(
                    (f) => DropdownMenuItem(
                      value: f,
                      child: Text(f.toUpperCase()),
                    ),
                  )
                  .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() => _selectedFormat = value);
            _updateSuggestedFileName();
          },
          decoration: const InputDecoration(
            labelText: '輸出格式',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: '輸出檔名',
            border: OutlineInputBorder(),
            helperText: '檔案將儲存到與原始檔案相同的資料夾',
          ),
        ),
      ],
    );
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      final start = Duration(milliseconds: (_selection.start * 1000).round());
      final end = Duration(milliseconds: (_selection.end * 1000).round());
      final pos = controller.value.position;
      if (pos >= end) {
        await controller.seekTo(start);
      }
      await controller.play();
    }
    if (mounted) {
      setState(() => _isPlaying = controller.value.isPlaying);
    }
  }

  Future<void> _seekRelative(Duration delta) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final durationMs =
        _mediaDuration.inMilliseconds > 0
            ? _mediaDuration.inMilliseconds
            : controller.value.duration.inMilliseconds;
    final maxMs = math.max(durationMs, 0);
    var target =
        controller.value.position.inMilliseconds + delta.inMilliseconds;
    if (target < 0) target = 0;
    if (target > maxMs) target = maxMs;
    await controller.seekTo(Duration(milliseconds: target));
    if (mounted) {
      setState(() {
        _currentPosition = Duration(milliseconds: target);
      });
    }
  }

  Future<void> _previewSelection() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final start = Duration(milliseconds: (_selection.start * 1000).round());
    await controller.seekTo(start);
    await controller.play();
    if (mounted) {
      setState(() => _isPlaying = true);
    }
  }

  void _setStartFromCurrent() {
    if (_durationSeconds <= 0) return;
    final current = _currentPosition.inMilliseconds / 1000.0;
    double newStart = current.clamp(0.0, _durationSeconds).toDouble();
    double newEnd = _selection.end.clamp(0.0, _durationSeconds).toDouble();
    final double minGap = math.min(_kMinSelectableSeconds, _durationSeconds);
    if (newEnd - newStart < minGap) {
      newEnd = math.min(_durationSeconds, newStart + minGap);
      if (newEnd - newStart < minGap) {
        newStart = math.max(0.0, newEnd - minGap);
      }
    }
    setState(() {
      _selection = RangeValues(newStart, newEnd);
    });
  }

  void _setEndFromCurrent() {
    if (_durationSeconds <= 0) return;
    final current = _currentPosition.inMilliseconds / 1000.0;
    double newEnd = current.clamp(0.0, _durationSeconds).toDouble();
    double newStart = _selection.start.clamp(0.0, _durationSeconds).toDouble();
    final double minGap = math.min(_kMinSelectableSeconds, _durationSeconds);
    if (newEnd - newStart < minGap) {
      newStart = math.max(0.0, newEnd - minGap);
      if (newEnd - newStart < minGap) {
        newEnd = math.min(_durationSeconds, newStart + minGap);
      }
    }
    setState(() {
      _selection = RangeValues(newStart, newEnd);
    });
  }

  void _updateSuggestedFileName({bool force = false}) {
    final suggestion = '${_baseName}_clip.${_selectedFormat}';
    final current = _nameController.text.trim();
    final shouldReplace =
        force || current.isEmpty || current == _lastSuggestedName;
    if (shouldReplace) {
      _lastSuggestedName = suggestion;
      _nameController.value = TextEditingValue(
        text: suggestion,
        selection: TextSelection.collapsed(offset: suggestion.length),
      );
    } else if (!current.toLowerCase().endsWith('.${_selectedFormat}')) {
      final withoutExt = _removeExtension(current);
      final updated = '$withoutExt.${_selectedFormat}';
      _nameController.value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: updated.length),
      );
    }
  }

  String _removeExtension(String name) {
    final ext = p.extension(name);
    if (ext.isEmpty) return name;
    return name.substring(0, name.length - ext.length);
  }

  Future<void> _startExport() async {
    if (_processing) return;
    if (_durationSeconds <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('無法取得媒體長度')));
      return;
    }
    final start = Duration(milliseconds: (_selection.start * 1000).round());
    final end = Duration(milliseconds: (_selection.end * 1000).round());
    final clipDuration = end - start;
    if (clipDuration <= Duration.zero) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('請選擇有效的時間範圍')));
      return;
    }
    var outputName = _nameController.text.trim();
    if (outputName.isEmpty) {
      _updateSuggestedFileName(force: true);
      outputName = _nameController.text.trim();
    }
    if (!outputName.toLowerCase().endsWith('.${_selectedFormat}')) {
      outputName = '${_removeExtension(outputName)}.${_selectedFormat}';
    }
    outputName = _sanitizeFileName(outputName);
    if (outputName.isEmpty) {
      outputName = '${_baseName}_clip.${_selectedFormat}';
    }
    if (_nameController.text.trim() != outputName) {
      _lastSuggestedName = outputName;
      _nameController.value = TextEditingValue(
        text: outputName,
        selection: TextSelection.collapsed(offset: outputName.length),
      );
    }
    final dir = File(widget.sourcePath).parent;
    final outputPath = _uniqueOutputPath(dir.path, outputName);
    final buffer = StringBuffer('-y ');
    if (start > Duration.zero) {
      buffer.write('-ss ${_ffmpegTimestamp(start)} ');
    }
    buffer.write("-i ${_quotePath(widget.sourcePath)} ");
    if (clipDuration > Duration.zero) {
      buffer.write('-t ${_ffmpegTimestamp(clipDuration)} ');
    }
    buffer.write('-vn ${_codecArguments(_selectedFormat)} ');
    buffer.write(_quotePath(outputPath));

    setState(() {
      _processing = true;
      _progress = 0.0;
      _cancelRequested = false;
      _lastOutputPath = null;
    });

    try {
      final session = await FFmpegKit.executeAsync(
        buffer.toString(),
        (session) async {
          final rc = await session.getReturnCode();
          final success = rc != null && rc.isValueSuccess();
          final cancelled = rc != null && rc.isValueCancel();
          if (mounted) {
            setState(() {
              _processing = false;
              _progress = null;
              _activeSessionId = null;
              _cancelRequested = false;
              if (success) {
                _lastOutputPath = outputPath;
              }
            });
          }
          if (mounted) {
            final messenger = ScaffoldMessenger.of(context);
            if (success) {
              messenger.showSnackBar(
                SnackBar(content: Text('匯出完成：${p.basename(outputPath)}')),
              );
            } else if (cancelled) {
              messenger.showSnackBar(const SnackBar(content: Text('已取消匯出')));
              try {
                final file = File(outputPath);
                if (await file.exists()) {
                  await file.delete();
                }
              } catch (_) {}
            } else {
              messenger.showSnackBar(
                const SnackBar(content: Text('匯出失敗，請稍後再試')),
              );
              try {
                final file = File(outputPath);
                if (await file.exists()) {
                  await file.delete();
                }
              } catch (_) {}
            }
          }
        },
        null,
        (statistics) {
          if (!mounted) return;
          final totalMs = clipDuration.inMilliseconds;
          if (totalMs <= 0) return;
          final time = statistics.getTime();
          if (time == null) return;
          final progress = (time / totalMs).clamp(0.0, 1.0);
          setState(() {
            _progress = progress;
          });
        },
      );
      final sessionId = await session.getSessionId();
      if (mounted) {
        setState(() {
          _activeSessionId = sessionId;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _processing = false;
          _progress = null;
          _activeSessionId = null;
          _cancelRequested = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('啟動轉檔失敗: $e')));
      }
    }
  }

  Future<void> _cancelExport() async {
    final sessionId = _activeSessionId;
    if (sessionId == null) return;
    setState(() {
      _cancelRequested = true;
    });
    try {
      await FFmpegKit.cancel(sessionId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('取消失敗，請稍後再試')));
      }
    }
  }

  void _openOutputLocation(String path) {
    // Placeholder: on mobile we cannot directly open file explorer.
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已匯出到：$path')));
  }

  String _codecArguments(String format) {
    switch (format) {
      case 'mp3':
        return '-c:a libmp3lame -qscale:a 2';
      case 'm4a':
      case 'aac':
        return '-c:a aac -b:a 192k';
      case 'wav':
        return '-c:a pcm_s16le -ar 44100';
      default:
        return '-c:a copy';
    }
  }

  String _quotePath(String path) {
    final escaped = path.replaceAll("'", "'\\''");
    return "'${escaped}'";
  }

  String _ffmpegTimestamp(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    final millis = d.inMilliseconds % 1000;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
  }

  String _formatReadable(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _sanitizeFileName(String name) {
    final cleaned =
        name
            .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
            .replaceAll('\n', ' ')
            .trim();
    if (cleaned.isEmpty) return 'export';
    return cleaned;
  }

  String _uniqueOutputPath(String directory, String name) {
    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    var attempt = p.join(directory, '$base$ext');
    var counter = 1;
    while (File(attempt).existsSync()) {
      attempt = p.join(directory, '$base($counter)$ext');
      counter++;
      if (counter > 99) {
        break;
      }
    }
    return attempt;
  }
}
