import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

import 'model_run_widgets.dart';

/// How the slide text is drawn. Values match the server's layout schema.
enum SlideStyle {
  outlined('outlined', 'Outlined'),
  whiteBox('white_box', 'White box'),
  darkBox('dark_box', 'Dark box');

  const SlideStyle(this.value, this.label);

  final String value;
  final String label;

  static SlideStyle from(Object? value) => SlideStyle.values.firstWhere(
    (style) => style.value == value,
    orElse: () => SlideStyle.outlined,
  );
}

/// Where the slide text goes. The server works out the box for each.
enum SlidePosition {
  reference('reference', 'As in reference'),
  top('top', 'Top'),
  middle('middle', 'Middle'),
  bottom('bottom', 'Bottom');

  const SlidePosition(this.value, this.label);

  final String value;
  final String label;

  static SlidePosition from(Object? value) => SlidePosition.values.firstWhere(
    (position) => position.value == value,
    orElse: () => SlidePosition.reference,
  );
}

/// The outcome of `render_slide`: the plan's text drawn on one image by the
/// server. Still unchecked against the blueprint, so for inspection only.
@immutable
class SlideRender {
  const SlideRender({
    required this.planId,
    required this.runId,
    required this.renderId,
    required this.status,
    required this.issues,
    required this.style,
    required this.position,
    required this.hasText,
    required this.lines,
    required this.imagePath,
  });

  factory SlideRender.fromMap(Map<String, dynamic> map) {
    final layout = callableMap(map['layout']);
    return SlideRender(
      planId: map['planId'] as String,
      runId: map['runId'] as String,
      renderId: map['renderId'] as String,
      status: map['status'] as String? ?? 'failed',
      issues: callableStrings(map['issues']),
      style: SlideStyle.from(layout['style']),
      position: SlidePosition.from(layout['position']),
      hasText: map['hasText'] == true,
      lines: callableStrings(map['lines']),
      imagePath: map['imagePath'] as String?,
    );
  }

  final String planId;

  /// The generation run whose image the text was drawn on.
  final String runId;
  final String renderId;

  /// `rendered` or `failed`.
  final String status;
  final List<String> issues;
  final SlideStyle style;
  final SlidePosition position;
  final bool hasText;
  final List<String> lines;

  /// Null unless the server's inspection switch is on.
  final String? imagePath;

  bool get rendered => status == 'rendered';
}

/// A failure the user can act on, with a message safe to show on screen.
class RenderException implements Exception {
  const RenderException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Draws a plan's slide text onto an image with `render_slide`.
class RenderService {
  Future<SlideRender> render(
    String assetId,
    String runId, {
    SlideStyle style = SlideStyle.outlined,
    SlidePosition position = SlidePosition.reference,
  }) async {
    try {
      final result = await FirebaseFunctions.instanceFor(region: 'us-central1')
          .httpsCallable(
            'render_slide',
            options: HttpsCallableOptions(timeout: const Duration(seconds: 40)),
          )
          .call<Map<String, dynamic>>({
            'assetId': assetId,
            'runId': runId,
            'layout': {'style': style.value, 'position': position.value},
          });
      return SlideRender.fromMap(callableMap(result.data));
    } on FirebaseFunctionsException catch (error) {
      debugPrint('JustPost: render_slide failed — ${error.code}');
      throw RenderException(_message(error));
    }
  }

  static String _message(FirebaseFunctionsException error) {
    return switch (error.code) {
      // These come from the backend's checks and are written for users.
      'invalid-argument' ||
      'not-found' ||
      'failed-precondition' ||
      'resource-exhausted' => error.message ?? 'Adding the text failed.',
      'deadline-exceeded' => 'Adding the text took too long. Please try again.',
      'unavailable' => 'The server is unavailable. Please try again.',
      _ => 'Adding the text failed. Please try again.',
    };
  }
}
