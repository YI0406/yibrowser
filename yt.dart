import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Represents the user-facing download kind for a YouTube stream option.
enum YtOptionType { muxed, videoAudio, videoOnly, audioOnly }

/// Structured metadata for a single YouTube stream option.
class YtStreamOption {
  const YtStreamOption({
    required this.id,
    required this.videoId,
    required this.type,
    required this.downloadUrl,
    required this.fileExtension,
    required this.container,
    this.audioUrl,
    this.audioContainer,
    this.videoCodec,
    this.audioCodec,
    this.qualityLabel,
    this.width,
    this.height,
    this.videoBitrate,
    this.audioBitrate,
    this.totalBitrate,
    this.itag,
    this.audioItag,
    this.duration,
    this.suggestedFileName,
  });

  final String id;
  final String videoId;
  final YtOptionType type;
  final String downloadUrl;
  final String fileExtension;
  final String container;
  final String? audioUrl;
  final String? audioContainer;
  final String? videoCodec;
  final String? audioCodec;
  final String? qualityLabel;
  final int? width;
  final int? height;
  final int? videoBitrate;
  final int? audioBitrate;
  final int? totalBitrate;
  final int? itag;
  final int? audioItag;
  final Duration? duration;
  final String? suggestedFileName;

  bool get requiresMerge => type == YtOptionType.videoAudio;
  bool get hasVideo =>
      type == YtOptionType.muxed ||
      type == YtOptionType.videoAudio ||
      type == YtOptionType.videoOnly;
  bool get hasAudio =>
      type == YtOptionType.muxed ||
      type == YtOptionType.videoAudio ||
      type == YtOptionType.audioOnly;
}

/// Encapsulates YouTube video metadata together with all preferred options.
class YtVideoInfo {
  const YtVideoInfo({
    required this.videoId,
    required this.title,
    required this.options,
    this.author,
    this.duration,
    this.watchUrl,
  });

  final String videoId;
  final String title;
  final List<YtStreamOption> options;
  final String? author;
  final Duration? duration;
  final String? watchUrl;
}

/// Fetch the available YouTube streams prioritising MP4/H.264 variants so that
/// the caller can remux without transcoding.
Future<YtVideoInfo> fetchYoutubeVideoInfo(String url) async {
  final yt = YoutubeExplode();
  try {
    final normalized = _normalizeYoutubeUrl(url);
    final extractedId = _extractYoutubeId(normalized);
    if (extractedId == null) {
      throw ArgumentError('Unable to parse YouTube video id from $url');
    }
    final videoId = VideoId(extractedId);
    final video = await yt.videos.get(videoId);
    final manifest = await _loadStreamManifest(yt, videoId);

    final muxedStreams =
        manifest.muxed.where(_isPreferredMuxed).toList()
          ..sort((a, b) => b.videoResolution.compareTo(a.videoResolution));

    final audioStreams =
        manifest.audioOnly.where(_isPreferredAudio).toList()
          ..sort((a, b) => b.bitrate.compareTo(a.bitrate));

    final videoOnlyStreams =
        manifest.videoOnly.where(_isPreferredVideoOnly).toList()
          ..sort((a, b) => b.videoResolution.compareTo(a.videoResolution));

    final List<YtStreamOption> muxedOptions =
        muxedStreams
            .map(
              (stream) => YtStreamOption(
                id: 'muxed-${stream.tag}',
                videoId: video.id.value,
                type: YtOptionType.muxed,
                downloadUrl: stream.url.toString(),
                fileExtension: stream.container.name,
                container: stream.container.name,
                videoCodec: stream.videoCodec,
                audioCodec: stream.audioCodec,
                qualityLabel: _nonEmpty(stream.qualityLabel),
                width: stream.videoResolution.width,
                height: stream.videoResolution.height,
                videoBitrate: stream.bitrate.bitsPerSecond,
                totalBitrate: stream.bitrate.bitsPerSecond,
                itag: stream.tag,
                duration: video.duration,
                suggestedFileName: _buildSuggestedName(
                  video.title,
                  stream.qualityLabel,
                  includeAudio: true,
                ),
              ),
            )
            .toList();

    final int bestMuxedHeight =
        muxedStreams.isEmpty
            ? 0
            : muxedStreams
                .map((s) => s.videoResolution.height)
                .reduce(math.max);

    final AudioOnlyStreamInfo? primaryAudio =
        audioStreams.isNotEmpty ? audioStreams.first : null;

    final List<YtStreamOption> comboOptions = <YtStreamOption>[];
    if (primaryAudio != null) {
      for (final stream in videoOnlyStreams) {
        final height = stream.videoResolution.height;
        if (muxedStreams.isNotEmpty && height <= bestMuxedHeight) {
          // Skip lower/equal resolutions that already exist as muxed options.
          continue;
        }
        comboOptions.add(
          YtStreamOption(
            id: 'va-${stream.tag}-${primaryAudio.tag}',
            videoId: video.id.value,
            type: YtOptionType.videoAudio,
            downloadUrl: stream.url.toString(),
            audioUrl: primaryAudio.url.toString(),
            fileExtension: 'mp4',
            container: 'mp4',
            audioContainer: primaryAudio.container.name,
            videoCodec: stream.videoCodec,
            audioCodec: primaryAudio.audioCodec,
            qualityLabel: _nonEmpty(stream.qualityLabel),
            width: stream.videoResolution.width,
            height: height,
            videoBitrate: stream.bitrate.bitsPerSecond,
            audioBitrate: primaryAudio.bitrate.bitsPerSecond,
            totalBitrate:
                stream.bitrate.bitsPerSecond +
                primaryAudio.bitrate.bitsPerSecond,
            itag: stream.tag,
            audioItag: primaryAudio.tag,
            duration: video.duration,
            suggestedFileName: _buildSuggestedName(
              video.title,
              stream.qualityLabel,
              includeAudio: true,
            ),
          ),
        );
      }
    }

    final List<YtStreamOption> videoOnlyOptions =
        videoOnlyStreams
            .map(
              (stream) => YtStreamOption(
                id: 'video-${stream.tag}',
                videoId: video.id.value,
                type: YtOptionType.videoOnly,
                downloadUrl: stream.url.toString(),
                fileExtension: 'mp4',
                container: stream.container.name,
                videoCodec: stream.videoCodec,
                qualityLabel: _nonEmpty(stream.qualityLabel),
                width: stream.videoResolution.width,
                height: stream.videoResolution.height,
                videoBitrate: stream.bitrate.bitsPerSecond,
                totalBitrate: stream.bitrate.bitsPerSecond,
                itag: stream.tag,
                duration: video.duration,
                suggestedFileName: _buildSuggestedName(
                  video.title,
                  stream.qualityLabel,
                  includeAudio: false,
                ),
              ),
            )
            .toList();

    final List<YtStreamOption> audioOnlyOptions =
        audioStreams
            .map(
              (stream) => YtStreamOption(
                id: 'audio-${stream.tag}',
                videoId: video.id.value,
                type: YtOptionType.audioOnly,
                downloadUrl: stream.url.toString(),
                fileExtension: stream.container.name,
                container: stream.container.name,
                audioCodec: stream.audioCodec,
                audioBitrate: stream.bitrate.bitsPerSecond,
                totalBitrate: stream.bitrate.bitsPerSecond,
                audioItag: stream.tag,
                duration: video.duration,
                suggestedFileName: _buildAudioSuggestedName(
                  video.title,
                  stream.bitrate.bitsPerSecond,
                ),
              ),
            )
            .toList();

    comboOptions.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
    videoOnlyOptions.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
    audioOnlyOptions.sort(
      (a, b) => (b.audioBitrate ?? 0).compareTo(a.audioBitrate ?? 0),
    );

    final combinedOptions = <YtStreamOption>[
      // Prioritize native muxed streams so users see the fastest single-file
      // downloads before combinations that require merging.
      ...muxedOptions,
      ...comboOptions,
      ...videoOnlyOptions,
      ...audioOnlyOptions,
    ];

    return YtVideoInfo(
      videoId: video.id.value,
      title: video.title,
      options: combinedOptions,
      author: video.author,
      duration: video.duration,
      watchUrl: _canonicalWatchUrl(video.id.value),
    );
  } finally {
    yt.close();
  }
}

String _normalizeYoutubeUrl(String rawUrl) {
  var url = rawUrl.trim();
  if (url.isEmpty) {
    throw ArgumentError('YouTube URL is empty');
  }
  if (url.startsWith('//')) {
    url = 'https:$url';
  }
  if (!url.startsWith(RegExp(r'https?://'))) {
    url = 'https://$url';
  }
  if (url.contains('youtube.com/shorts/') && !url.contains('www.')) {
    url = url.replaceFirst('https://youtube.com', 'https://www.youtube.com');
  }
  return url;
}

String? _extractYoutubeId(String rawUrl) {
  // Accept raw IDs directly (11-char base64url-like)
  final String url = rawUrl.trim();
  final RegExp idRx = RegExp(r'^[a-zA-Z0-9_-]{11}$');
  if (idRx.hasMatch(url)) return url;

  Uri? uri;
  try {
    uri = Uri.parse(url);
  } catch (_) {
    return null;
  }

  // youtu.be/<id>?...
  if (uri.host.contains('youtu.be')) {
    if (uri.pathSegments.isNotEmpty) {
      final id = uri.pathSegments.first;
      return idRx.hasMatch(id) ? id : null;
    }
    return null;
  }

  // *.youtube.com/* cases
  final host = uri.host;
  if (host.contains('youtube.com')) {
    // /watch?v=<id>
    final v = uri.queryParameters['v'];
    if (v != null && idRx.hasMatch(v)) return v;

    // /shorts/<id>
    if (uri.pathSegments.isNotEmpty && uri.pathSegments.first == 'shorts') {
      final id = uri.pathSegments.length > 1 ? uri.pathSegments[1] : null;
      if (id != null && idRx.hasMatch(id)) return id;
    }

    // /embed/<id>
    if (uri.pathSegments.isNotEmpty && uri.pathSegments.first == 'embed') {
      final id = uri.pathSegments.length > 1 ? uri.pathSegments[1] : null;
      if (id != null && idRx.hasMatch(id)) return id;
    }

    // /live/<id> (sometimes used)
    if (uri.pathSegments.isNotEmpty && uri.pathSegments.first == 'live') {
      final id = uri.pathSegments.length > 1 ? uri.pathSegments[1] : null;
      if (id != null && idRx.hasMatch(id)) return id;
    }
  }

  // Fallback: scan entire string for an ID-looking token
  final RegExp anywhere = RegExp(r'[a-zA-Z0-9_-]{11}');
  final match = anywhere.firstMatch(url);
  return match?.group(0);
}

String _canonicalWatchUrl(String videoId) {
  return 'https://www.youtube.com/watch?v=$videoId';
}

bool _isPreferredMuxed(MuxedStreamInfo stream) {
  return stream.container == StreamContainer.mp4 && _isH264(stream.videoCodec);
}

bool _isPreferredVideoOnly(VideoOnlyStreamInfo stream) {
  return stream.container == StreamContainer.mp4 && _isH264(stream.videoCodec);
}

bool _isPreferredAudio(AudioOnlyStreamInfo stream) {
  return stream.container == StreamContainer.mp4 &&
      stream.audioCodec.toLowerCase().contains('mp4a');
}

bool _isH264(String codec) => codec.toLowerCase().contains('avc');

String? _nonEmpty(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String _buildSuggestedName(
  String rawTitle,
  String? qualityLabel, {
  required bool includeAudio,
}) {
  final base = rawTitle.trim().isEmpty ? 'YouTube Video' : rawTitle.trim();
  final quality = qualityLabel?.trim();
  if (quality == null || quality.isEmpty) {
    return includeAudio ? '$base (video+audio)' : '$base (video)';
  }
  return includeAudio ? '$base ($quality)' : '$base ($quality video)';
}

String _buildAudioSuggestedName(String rawTitle, int? bitrate) {
  final base = rawTitle.trim().isEmpty ? 'YouTube Audio' : rawTitle.trim();
  final kbps = bitrate != null ? (bitrate / 1000).round() : null;
  return kbps != null ? '$base (${kbps}kbps audio)' : '$base (audio)';
}

/// Attempt to extract a YouTube video id from arbitrary input.
String? extractYoutubeVideoId(String url) {
  try {
    final normalized = _normalizeYoutubeUrl(url);
    return _extractYoutubeId(normalized);
  } catch (_) {
    return _extractYoutubeId(url);
  }
}

/// Downloads the stream identified by [itag] for the YouTube [videoId] into
/// [destinationPath]. Returns the number of bytes written. Throws
/// [YoutubeStreamCancelled] if [shouldAbort] reports true during transfer.
Future<int> downloadYoutubeStreamToFile({
  required String videoId,
  required int itag,
  required String destinationPath,
  void Function(int chunkBytes)? onBytes,
  bool Function()? shouldAbort,
}) async {
  final yt = YoutubeExplode();

  try {
    Future<StreamInfo> loadStreamInfo() async {
      final manifest = await yt.videos.streamsClient.getManifest(
        VideoId(videoId),
      );
      return manifest.streams.firstWhere(
        (element) => element.tag == itag,
        orElse:
            () =>
                throw StateError(
                  'Stream with itag $itag not found for $videoId',
                ),
      );
    }

    Future<int> runSequential(StreamInfo info) async {
      return _downloadStreamSequential(
        yt: yt,
        streamInfo: info,
        destinationPath: destinationPath,
        onBytes: onBytes,
        shouldAbort: shouldAbort,
      );
    }

    final initialStreamInfo = await loadStreamInfo();
    final totalBytes = initialStreamInfo.size.totalBytes;

    if (totalBytes == null || totalBytes <= 0) {
      return await runSequential(initialStreamInfo);
    }

    final downloader = _YoutubeParallelDownloader(
      destinationPath: destinationPath,
      totalBytes: totalBytes,
      initialUrl: initialStreamInfo.url.toString(),
      onBytes: onBytes,
      shouldAbort: shouldAbort,
      parallelConnections: _pickParallelConnectionCount(totalBytes),
      resumeFilePath: '$destinationPath.resume.json',
      urlRefresher: () async => (await loadStreamInfo()).url.toString(),
    );
    try {
      return await downloader.download();
    } on YoutubeStreamCancelled {
      rethrow;
    } on _ParallelDownloadUnsupported {
      final refreshed = await loadStreamInfo();
      return await runSequential(refreshed);
    } catch (_) {
      final refreshed = await loadStreamInfo();
      return await runSequential(refreshed);
    }
  } finally {
    yt.close();
  }
}

class YoutubeStreamCancelled implements Exception {
  const YoutubeStreamCancelled();
}

int _pickParallelConnectionCount(int totalBytes) {
  if (totalBytes < 8 * 1024 * 1024) {
    return 6;
  }
  if (totalBytes < 48 * 1024 * 1024) {
    return 8;
  }
  return 12;
}

Future<int> _downloadStreamSequential({
  required YoutubeExplode yt,
  required StreamInfo streamInfo,
  required String destinationPath,
  void Function(int chunkBytes)? onBytes,
  bool Function()? shouldAbort,
}) async {
  IOSink? sink;
  final file = File(destinationPath);
  try {
    if (await file.exists()) {
      await file.delete();
    }
    await file.create(recursive: true);
    sink = file.openWrite();
    final stream = yt.videos.streamsClient.get(streamInfo);
    await for (final chunk in stream) {
      if (shouldAbort?.call() ?? false) {
        throw const YoutubeStreamCancelled();
      }
      if (chunk.isEmpty) {
        continue;
      }
      sink.add(chunk);
      onBytes?.call(chunk.length);
    }
    await sink.flush();
  } finally {
    if (sink != null) {
      try {
        await sink.flush();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
    }
  }
  return await file.exists() ? await file.length() : 0;
}

class _ParallelDownloadUnsupported implements Exception {
  const _ParallelDownloadUnsupported(this.message);

  final String message;

  @override
  String toString() => 'Parallel download unsupported: $message';
}

class _ResumeLoadResult {
  const _ResumeLoadResult({required this.downloaded, required this.isComplete});

  final int downloaded;
  final bool isComplete;
}

class _RemoteMetadata {
  const _RemoteMetadata({required this.supportsRanges, this.total, this.etag});

  final bool supportsRanges;
  final int? total;
  final String? etag;
}

class _SegmentProgress {
  _SegmentProgress({required this.start, required this.end}) : downloaded = 0;

  final int start;
  final int end;
  int downloaded;

  int get length => end - start + 1;

  bool get isComplete => downloaded >= length;
}

class _YoutubeParallelDownloader {
  _YoutubeParallelDownloader({
    required this.destinationPath,
    required int totalBytes,
    required this.initialUrl,
    required this.parallelConnections,
    required this.resumeFilePath,
    required this.urlRefresher,
    this.onBytes,
    this.shouldAbort,
  }) : totalBytes = totalBytes;

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0.0.0 Safari/537.36';
  static const int _resumeFlushThreshold = 512 * 1024;

  final String destinationPath;
  int totalBytes;
  final String initialUrl;
  final int parallelConnections;
  final String resumeFilePath;
  final Future<String> Function() urlRefresher;
  final void Function(int chunkBytes)? onBytes;
  final bool Function()? shouldAbort;

  HttpClient? _client;
  String? _currentUrl;
  Future<String>? _refreshing;
  String? _etag;
  List<_SegmentProgress> _segments = <_SegmentProgress>[];
  Future<void> _pendingSave = Future<void>.value();

  Future<int> download() async {
    _client =
        HttpClient()
          ..userAgent = _userAgent
          ..connectionTimeout = const Duration(seconds: 20)
          ..maxConnectionsPerHost = math.max(6, parallelConnections + 2);
    _currentUrl = initialUrl;
    try {
      final metadata = await _probeMetadata();
      if (!metadata.supportsRanges) {
        throw const _ParallelDownloadUnsupported(
          'server does not support Range requests',
        );
      }
      if (metadata.total != null && metadata.total! > 0) {
        totalBytes = metadata.total!;
      }
      _etag ??= metadata.etag;
      if (totalBytes <= 0) {
        throw const _ParallelDownloadUnsupported('missing content length');
      }
      _segments = _buildSegments(totalBytes);
      await _ensureOutputFile(totalBytes);
      await _persistResume();
      final resume = await _loadResumeProgress();
      if (resume.isComplete) {
        await _cleanupResume();
        return await _finalizeLength();
      }
      if (resume.downloaded > 0) {
        onBytes?.call(resume.downloaded);
      }
      final segments = _segments;
      final concurrency = math.max(
        1,
        math.min(parallelConnections, segments.length),
      );
      if (concurrency <= 0) {
        throw const _ParallelDownloadUnsupported('no segments to download');
      }

      var nextIndex = 0;
      _SegmentProgress? nextSegment() {
        while (nextIndex < segments.length) {
          final seg = segments[nextIndex++];
          if (!seg.isComplete) {
            return seg;
          }
        }
        return null;
      }

      final workers = <Future<void>>[];
      for (var i = 0; i < concurrency; i++) {
        final initial = nextSegment();
        if (initial == null) {
          break;
        }
        workers.add(_spawnWorker(initial, nextSegment));
      }

      await Future.wait(workers);
      await _cleanupResume();
      return await _finalizeLength();
    } finally {
      await _pendingSave;
      _client?.close(force: true);
      _client = null;
    }
  }

  Future<void> _spawnWorker(
    _SegmentProgress first,
    _SegmentProgress? Function() nextSegment,
  ) async {
    var current = first;
    while (true) {
      if (shouldAbort?.call() ?? false) {
        throw const YoutubeStreamCancelled();
      }
      await _downloadSegment(current);
      final next = nextSegment();
      if (next == null) {
        break;
      }
      current = next;
    }
  }

  Future<_RemoteMetadata> _probeMetadata() async {
    const maxAttempts = 5;
    var attempt = 0;
    while (attempt < maxAttempts) {
      attempt += 1;
      final url = await _ensureUrl(forceRefresh: attempt > 1);
      final client = _client;
      if (client == null) {
        throw StateError('HTTP client not initialised');
      }
      try {
        final request = await client.getUrl(Uri.parse(url));
        _applyBaseHeaders(request);
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        final response = await request.close();
        if (response.statusCode == HttpStatus.partialContent) {
          final total = _parseTotalFromContentRange(
            response.headers.value(HttpHeaders.contentRangeHeader),
          );
          final etag = response.headers.value(HttpHeaders.etagHeader);
          await response.drain();
          return _RemoteMetadata(
            supportsRanges: true,
            total: total ?? totalBytes,
            etag: etag,
          );
        }
        if (response.statusCode == HttpStatus.ok) {
          final contentLength = response.headers.value(
            HttpHeaders.contentLengthHeader,
          );
          final total = int.tryParse(contentLength ?? '');
          await response.drain();
          return _RemoteMetadata(
            supportsRanges: false,
            total: total,
            etag: response.headers.value(HttpHeaders.etagHeader),
          );
        }
        if (_isExpiredStatus(response.statusCode)) {
          await response.drain();
          await _refreshUrl();
          continue;
        }
        if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
          final total = _parseTotalFromContentRange(
            response.headers.value(HttpHeaders.contentRangeHeader),
          );
          await response.drain();
          return _RemoteMetadata(
            supportsRanges: true,
            total: total ?? totalBytes,
            etag: response.headers.value(HttpHeaders.etagHeader),
          );
        }
        await response.drain();
      } on SocketException {
        // transient; retry
      }
      await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
    }
    throw const _ParallelDownloadUnsupported('unable to probe remote metadata');
  }

  List<_SegmentProgress> _buildSegments(int total) {
    final segments = <_SegmentProgress>[];
    final desiredSegments = math.max(
      parallelConnections * 2,
      parallelConnections,
    );
    final chunkSize = math.max(1024 * 1024, (total / desiredSegments).ceil());
    var start = 0;
    while (start < total) {
      final end = math.min(start + chunkSize - 1, total - 1);
      segments.add(_SegmentProgress(start: start, end: end));
      start = end + 1;
    }
    return segments;
  }

  Future<_ResumeLoadResult> _loadResumeProgress() async {
    final resumeFile = File(resumeFilePath);
    if (!await resumeFile.exists()) {
      return const _ResumeLoadResult(downloaded: 0, isComplete: false);
    }
    try {
      final raw = jsonDecode(await resumeFile.readAsString());
      if (raw is! Map<String, dynamic>) {
        await resumeFile.delete();
        return const _ResumeLoadResult(downloaded: 0, isComplete: false);
      }
      final storedTotal = (raw['total'] as num?)?.toInt();
      final storedEtag = raw['etag'] as String?;
      final storedUrl = raw['lastUrl'] as String?;
      if (_etag != null && storedEtag != null && storedEtag != _etag) {
        await resumeFile.delete();
        return const _ResumeLoadResult(downloaded: 0, isComplete: false);
      }
      if (_etag == null && storedEtag != null) {
        _etag = storedEtag;
      }
      if (storedUrl != null && storedUrl.isNotEmpty) {
        _currentUrl = storedUrl;
      }
      if (storedTotal != null && storedTotal > 0 && storedTotal != totalBytes) {
        totalBytes = storedTotal;
        _segments = _buildSegments(totalBytes);
        await _ensureOutputFile(totalBytes);
      }
      final parts = raw['parts'];
      if (parts is! List) {
        await resumeFile.delete();
        return const _ResumeLoadResult(downloaded: 0, isComplete: false);
      }
      final file = File(destinationPath);
      final exists = await file.exists();
      final fileLength = exists ? await file.length() : 0;
      final segmentByStart = <int, _SegmentProgress>{
        for (final seg in _segments) seg.start: seg,
      };
      for (final entry in parts) {
        if (entry is! Map<String, dynamic>) {
          continue;
        }
        final start = (entry['start'] as num?)?.toInt();
        final end = (entry['end'] as num?)?.toInt();
        final downloaded = (entry['downloaded'] as num?)?.toInt() ?? 0;
        if (start == null || end == null) {
          continue;
        }
        final seg = segmentByStart[start];
        if (seg == null || seg.end != end) {
          continue;
        }
        final maxAvailable = math.max(
          0,
          math.min(seg.length, fileLength - seg.start),
        );
        if (maxAvailable <= 0) {
          seg.downloaded = 0;
          continue;
        }
        seg.downloaded = math.max(0, math.min(downloaded, maxAvailable));
      }
      final downloadedTotal = _segments.fold<int>(
        0,
        (sum, seg) => sum + seg.downloaded,
      );
      final clamped = math.min(downloadedTotal, totalBytes);
      final isComplete =
          clamped >= totalBytes && _segments.every((seg) => seg.isComplete);
      return _ResumeLoadResult(downloaded: clamped, isComplete: isComplete);
    } catch (_) {
      await resumeFile.delete();
      return const _ResumeLoadResult(downloaded: 0, isComplete: false);
    }
  }

  Future<void> _ensureOutputFile(int total) async {
    final file = File(destinationPath);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    if (total <= 0) {
      return;
    }
    final currentLength = await file.length();
    if (currentLength < total) {
      final raf = await file.open(mode: FileMode.writeOnlyAppend);
      try {
        await raf.setPosition(total - 1);
        await raf.writeFrom(const [0]);
      } finally {
        await raf.close();
      }
    } else if (currentLength > total) {
      final raf = await file.open(mode: FileMode.writeOnly);
      try {
        await raf.truncate(total);
      } finally {
        await raf.close();
      }
    }
  }

  Future<void> _downloadSegment(_SegmentProgress segment) async {
    const maxAttempts = 6;
    var attempt = 0;
    try {
      while (true) {
        attempt += 1;
        if (shouldAbort?.call() ?? false) {
          throw const YoutubeStreamCancelled();
        }
        final start = segment.start + segment.downloaded;
        if (start > segment.end) {
          segment.downloaded = segment.length;
          return;
        }
        final url = await _ensureUrl();
        final client = _client;
        if (client == null) {
          throw StateError('HTTP client not initialised');
        }
        final request = await client.getUrl(Uri.parse(url));
        _applyBaseHeaders(request);
        request.headers.set(
          HttpHeaders.rangeHeader,
          'bytes=$start-${segment.end}',
        );
        final response = await request.close();
        if (response.statusCode == HttpStatus.partialContent ||
            (response.statusCode == HttpStatus.ok &&
                start == 0 &&
                segment.end == totalBytes - 1)) {
          _etag ??= response.headers.value(HttpHeaders.etagHeader);
          final raf = await File(
            destinationPath,
          ).open(mode: FileMode.writeOnly);
          var bytesSinceFlush = 0;
          try {
            await raf.setPosition(start);
            await for (final chunk in response) {
              if (chunk.isEmpty) {
                continue;
              }
              if (shouldAbort?.call() ?? false) {
                throw const YoutubeStreamCancelled();
              }
              await raf.writeFrom(chunk);
              segment.downloaded += chunk.length;
              bytesSinceFlush += chunk.length;
              onBytes?.call(chunk.length);
              if (bytesSinceFlush >= _resumeFlushThreshold) {
                await _persistResume();
                bytesSinceFlush = 0;
              }
            }
            await raf.flush();
          } finally {
            await raf.close();
          }
          if (segment.downloaded > segment.length) {
            segment.downloaded = segment.length;
          }
          return;
        }
        if (_isExpiredStatus(response.statusCode)) {
          await response.drain();
          await _refreshUrl();
          if (attempt >= maxAttempts) {
            throw const _ParallelDownloadUnsupported(
              'expired URL could not be refreshed',
            );
          }
          continue;
        }
        if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
          await response.drain();
          segment.downloaded = segment.length;
          return;
        }
        await response.drain();
        if (attempt >= maxAttempts) {
          throw HttpException('Unexpected status ${response.statusCode}');
        }
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
      }
    } finally {
      await _persistResume();
    }
  }

  Future<void> _persistResume() {
    final data = _serializeResume();
    _pendingSave = _pendingSave.then((_) async {
      final file = File(resumeFilePath);
      try {
        await file.parent.create(recursive: true);
      } catch (_) {}
      await file.writeAsString(jsonEncode(data), flush: true);
    });
    return _pendingSave;
  }

  Map<String, dynamic> _serializeResume() {
    return <String, dynamic>{
      'total': totalBytes,
      if (_etag != null) 'etag': _etag,
      if (_currentUrl != null) 'lastUrl': _currentUrl,
      'parts': [
        for (final seg in _segments)
          {'start': seg.start, 'end': seg.end, 'downloaded': seg.downloaded},
      ],
    };
  }

  Future<void> _cleanupResume() async {
    await _pendingSave;
    final file = File(resumeFilePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<int> _finalizeLength() async {
    final file = File(destinationPath);
    if (await file.exists()) {
      return await file.length();
    }
    return 0;
  }

  Future<String> _ensureUrl({bool forceRefresh = false}) async {
    if (forceRefresh || _currentUrl == null || _currentUrl!.isEmpty) {
      return _refreshUrl();
    }
    return _currentUrl!;
  }

  Future<String> _refreshUrl() async {
    final ongoing = _refreshing;
    if (ongoing != null) {
      return ongoing;
    }
    final future = urlRefresher();
    _refreshing = future;
    try {
      final value = await future;
      _currentUrl = value;
      return value;
    } finally {
      if (identical(_refreshing, future)) {
        _refreshing = null;
      }
    }
  }

  void _applyBaseHeaders(HttpClientRequest request) {
    request.headers.set(HttpHeaders.acceptHeader, '*/*');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.headers.set(HttpHeaders.connectionHeader, 'keep-alive');
  }

  bool _isExpiredStatus(int status) {
    return status == HttpStatus.unauthorized ||
        status == HttpStatus.forbidden ||
        status == HttpStatus.notFound ||
        status == HttpStatus.gone;
  }

  int? _parseTotalFromContentRange(String? header) {
    if (header == null || header.isEmpty) {
      return null;
    }
    final parts = header.split('/');
    if (parts.length != 2) {
      return null;
    }
    final totalPart = parts.last.trim();
    return int.tryParse(totalPart);
  }
}

Future<StreamManifest> _loadStreamManifest(
  YoutubeExplode yt,
  VideoId videoId,
) async {
  final attempts = <List<YoutubeApiClient>>[
    [YoutubeApiClient.ios, YoutubeApiClient.androidVr],
    [YoutubeApiClient.androidVr, YoutubeApiClient.safari],
    [YoutubeApiClient.tv],
    [YoutubeApiClient.ios, YoutubeApiClient.mweb],
  ];

  Object? lastError;
  StackTrace? lastStack;

  for (final clients in attempts) {
    try {
      final manifest = await yt.videos.streamsClient.getManifest(
        videoId,
        ytClients: clients,
      );
      if (manifest.streams.isNotEmpty) {
        return manifest;
      }
    } catch (e, s) {
      lastError = e;
      lastStack = s;
    }
  }

  try {
    return await yt.videos.streamsClient.getManifest(videoId);
  } catch (e, s) {
    lastError = e;
    lastStack = s;
  }

  if (lastError != null) {
    if (lastError is Error) {
      Error.throwWithStackTrace(lastError, lastStack ?? StackTrace.current);
    }
    if (lastError is Exception) {
      throw lastError;
    }
  }

  throw YoutubeExplodeException(
    'Unable to load streams for video ${videoId.value}',
  );
}
