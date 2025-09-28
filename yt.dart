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
  IOSink? sink;
  try {
    final manifest = await yt.videos.streamsClient.getManifest(
      VideoId(videoId),
    );
    final streamInfo = manifest.streams.firstWhere(
      (element) => element.tag == itag,
      orElse:
          () =>
              throw StateError('Stream with itag $itag not found for $videoId'),
    );
    final stream = yt.videos.streamsClient.get(streamInfo);
    final file = File(destinationPath);
    if (await file.exists()) {
      await file.delete();
    }
    await file.create(recursive: true);
    sink = file.openWrite();
    await for (final chunk in stream) {
      if (shouldAbort?.call() ?? false) {
        throw const YoutubeStreamCancelled();
      }
      sink.add(chunk);
      onBytes?.call(chunk.length);
    }
    await sink.flush();
    await sink.close();
    sink = null;
    return await file.exists() ? await file.length() : 0;
  } finally {
    if (sink != null) {
      try {
        await sink.flush();
      } catch (_) {}
      try {
        await sink.close();
      } catch (_) {}
    }
    yt.close();
  }
}

class YoutubeStreamCancelled implements Exception {
  const YoutubeStreamCancelled();
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
