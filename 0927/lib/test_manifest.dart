import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final yt = YoutubeExplode();
  try {
    final videoId = args.isNotEmpty ? args.first : '1G7SeLu2GEM';
    final manifest = await yt.videos.streamsClient.getManifest(videoId);
    print('streams: ${manifest.streams.length}');
    for (final s in manifest.streams.take(10)) {
      print('${s.runtimeType} tag=${s.tag} container=${s.container} codec=${s.codec}');
    }
  } catch (e, s) {
    print('error: $e');
    print(s);
  } finally {
    yt.close();
  }
}
