import 'dart:async';

import 'package:flutter/material.dart';
import 'package:arcore_flutter_plugin/arcore_flutter_plugin.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' as vector;
import 'dart:math' as math;

extension ArCoreControllerExtension on ArCoreController {
  Future<List<ArCoreHitTestResult>> performHitTest({required double x, required double y}) async {
    try {

      const MethodChannel arCoreChannel = MethodChannel('arcore_flutter_plugin/hit_test');


      final List<dynamic> hitTestResultsLocal = await arCoreChannel.invokeMethod('hitTest', {
        'x': x,
        'y': y,
      });

      final List<ArCoreHitTestResult> processedResults = hitTestResultsLocal
          .map((result) => ArCoreHitTestResult.fromMap(result))
          .toList();

      return processedResults;
    } catch (e) {
      print('Error during hit test: $e');
      return [];
    }
  }
}

class Vector3 {
  static vector.Vector3 fromList(List<dynamic> list) {
    return vector.Vector3(
        (list[0] as num).toDouble(),
        (list[1] as num).toDouble(),
        (list[2] as num).toDouble()
    );
  }
}

class Vector4 {
  static vector.Vector4 fromList(List<dynamic> list) {
    return vector.Vector4(
        (list[0] as num).toDouble(),
        (list[1] as num).toDouble(),
        (list[2] as num).toDouble(),
        (list[3] as num).toDouble()
    );
  }
}
class SurfaceUtils {
  static List<vector.Vector3> calculatePolygonVertices(List<vector.Vector3> points) {
    if (points.length < 3) return [];
    double avgHeight = points.fold(0.0, (sum, p) => sum + p.y) / points.length;
    return points.map((p) => vector.Vector3(p.x, avgHeight, p.z)).toList();
  }

  static double calculatePolygonArea(List<vector.Vector3> vertices) {
    if (vertices.length < 3) return 0.0;

    double area = 0.0;
    for (int i = 0; i < vertices.length; i++) {
      int j = (i + 1) % vertices.length;
      area += vertices[i].x * vertices[j].z - vertices[j].x * vertices[i].z;
    }
    return (area.abs() / 2.0);
  }

  static double calculatePerimeter(List<vector.Vector3> vertices) {
    if (vertices.length < 2) return 0.0;

    double perimeter = 0.0;
    for (int i = 0; i < vertices.length; i++) {
      int j = (i + 1) % vertices.length;
      perimeter += (vertices[i] - vertices[j]).length;
    }
    return perimeter;
  }
}

class LineSegment {
  final ArCoreNode node;
  final String id;

  LineSegment({required this.node, required this.id});
}

class MeasurementPoint {
  final vector.Vector3 position;
  final ArCoreNode node;
  final String id;

  MeasurementPoint({
    required this.position,
    required this.node,
    required this.id,
  });
}

class RomMeasurementScreen extends StatefulWidget {
  const RomMeasurementScreen({super.key});

  @override
  _RomMeasurementScreenState createState() => _RomMeasurementScreenState();
}

class _RomMeasurementScreenState extends State<RomMeasurementScreen> {
  late ArCoreController arCoreController;
  List<MeasurementPoint> measurementPoints = [];
  List<LineSegment> lineSegments = [];
  double areaPi2 = 0;
  double perimeterM = 0;
  bool isMarkerMode = true;
  bool isSurfaceFixed = false;
  bool isUpdateMode = false;
  bool isUpdateConfirmationMode = false;
  vector.Vector3? updatePosition;
  Color updateButtonColor = Colors.orange;
  bool isPointSelected = false;
  bool isDeleteMode = false; // Ajouter cette variable
  static const selectedForUpdateColor = Colors.yellow;
  bool isDragging = false;
  Timer? updateTimer;

  bool isPlaneDetected = false;
  String statusMessage = 'Initialisation...';
  vector.Vector3? planeNormal;
  vector.Vector3? planeCenter;
  ArCorePlane? currentPlane;
  ArCoreNode? surfaceNode;
  MeasurementPoint? selectedPoint;

  static const markerColor = Colors.blue;
  static const selectedMarkerColor = Colors.red;
  static const lineColor = Color.fromARGB(255, 255, 255, 0);
  static const markerSize = 0.01;
  static const lineWidth = 0.005;


  @override
  void initState() {
    super.initState();
    checkArCore();
  }

  Future<void> checkArCore() async {
    try {
      bool available = await ArCoreController.checkArCoreAvailability();
      if (!mounted) return;
      setState(() {
        statusMessage =
        available ? 'ARCore disponible' : 'ARCore non disponible';
      });

      bool installed = await ArCoreController.checkIsArCoreInstalled();
      if (!mounted) return;
      setState(() {
        statusMessage = installed ? 'ARCore installé' : 'ARCore non installé';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        statusMessage = 'Erreur lors de la vérification ARCore';
      });
    }
  }
  void _handlePlaneTap(List<ArCoreHitTestResult> hits) {
    if (!isMarkerMode || isSurfaceFixed) return;

    final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final size = renderBox.size;
    final centerX = size.width / 2;
    final centerY = size.height / 2;

    arCoreController.performHitTest(x: centerX, y: centerY).then((hits) {
      if (hits.isNotEmpty) {
        final hit = hits.first;
        final position = _projectPointOnPlane(hit.pose.translation);

        if (isUpdateMode && selectedPoint != null) {
          if (!isDragging) {
            setState(() {
              isDragging = true;
              statusMessage = 'Déplacement en cours...';
            });

            updateTimer?.cancel();
            updateTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
              _updatePointAndLinesPosition(position);
            });
          } else {
            setState(() {
              isDragging = false;
              updateTimer?.cancel();
              updateTimer = null;
              _finalizePointMove(position);
              statusMessage = 'Point déplacé';
            });
          }
        } else {
          _addPoint(position);
          if (measurementPoints.length >= 3) {
            _updateSurface();
            _calculateArea();
          }
        }
      }
    });
  }


  void _handleReticleTap(List<ArCoreHitTestResult> hits) {
    if (hits.isNotEmpty) {
      final hit = hits.first;
      final position = _projectPointOnPlane(hit.pose.translation);
      _addPoint(position);
    }
  }

  void _updatePointAndLinesPosition(vector.Vector3 newPosition) {
    if (selectedPoint == null) return;

    setState(() {
      final selectedIndex = measurementPoints.indexWhere((p) => p.id == selectedPoint!.id);
      if (selectedIndex == -1) return;

      // Mettre à jour la position du point
      final updatedPointNode = ArCoreNode(
        name: selectedPoint!.id,
        shape: ArCoreSphere(
          radius: markerSize,
          materials: [ArCoreMaterial(color: selectedForUpdateColor)],
        ),
        position: newPosition,
      );

      arCoreController.removeNode(nodeName: selectedPoint!.id);
      arCoreController.addArCoreNode(updatedPointNode);


      measurementPoints[selectedIndex] = MeasurementPoint(
        position: newPosition,
        node: updatedPointNode,
        id: selectedPoint!.id,
      );


      final previousIndex = (selectedIndex - 1 + measurementPoints.length) % measurementPoints.length;
      final nextIndex = (selectedIndex + 1) % measurementPoints.length;

      for (var line in lineSegments.where((l) =>
      l.id == 'line_$previousIndex' || l.id == 'line_$selectedIndex')) {
        arCoreController.removeNode(nodeName: line.node.name);
      }
      lineSegments.removeWhere((l) =>
      l.id == 'line_$previousIndex' || l.id == 'line_$selectedIndex');


      _addLine(
          measurementPoints[previousIndex].position,
          newPosition,
          'line_$previousIndex',
          selectedForUpdateColor
      );

      _addLine(
          newPosition,
          measurementPoints[nextIndex].position,
          'line_$selectedIndex',
          selectedForUpdateColor
      );
    });
  }

  void _onNodeTap(String nodeName) {
    if (!isUpdateMode && !isDeleteMode) return; // Sortir si pas en mode mise à jour ou suppression

    final tappedPoint = measurementPoints.firstWhere(
          (point) => point.id == nodeName,
      orElse: () => null as MeasurementPoint,
    );

    if (tappedPoint == null) return;

    setState(() {
      if (isDeleteMode) {
        _deletePoint(tappedPoint);
      } else if (isUpdateMode) {
        // Si un point était déjà sélectionné, réinitialiser sa couleur
        if (selectedPoint != null) {
          _updatePointColor(selectedPoint!, markerColor);
          _resetConnectedLinesColor();
        }

        // Sélectionner le nouveau point
        selectedPoint = tappedPoint;
        _updatePointColor(tappedPoint, selectedForUpdateColor);
        _highlightConnectedLines(tappedPoint);
        statusMessage = 'Cliquez où vous voulez déplacer le point';
      }
    });
  }


  void _exitUpdateMode() {
    setState(() {
      isUpdateMode = false;
      if (selectedPoint != null) {
        _updatePointColor(selectedPoint!, markerColor);
        _resetConnectedLinesColor();
        selectedPoint = null;
      }
      updateButtonColor = Colors.orange;
      statusMessage = 'Point mis à jour';
    });
  }

  void _moveSelectedPoint(vector.Vector3 newPosition) {
    if (selectedPoint == null) return;


    arCoreController.removeNode(nodeName: selectedPoint!.id);

    final updatedPointNode = ArCoreNode(
      name: selectedPoint!.id,
      shape: ArCoreSphere(
        radius: markerSize,
        materials: [ArCoreMaterial(color: markerColor)],
      ),
      position: newPosition,
    );

    arCoreController.addArCoreNode(updatedPointNode);

    setState(() {
      final index = measurementPoints.indexOf(selectedPoint!);
      if (index != -1) {
        measurementPoints[index] = MeasurementPoint(
          position: newPosition,
          node: updatedPointNode,
          id: selectedPoint!.id,
        );
      }

      _updateLines();


      if (measurementPoints.length >= 3) {
        _updateSurface();
        _calculateArea();
      }
    });
  }
  void _deletePoint(MeasurementPoint point) {
    setState(() {
      arCoreController.removeNode(nodeName: point.id);


      measurementPoints.remove(point);


      _removeAllLines();
      _updateLines();


      if (measurementPoints.length >= 3) {
        _updateSurface();
        _calculateArea();
      } else {
        if (surfaceNode != null) {
          arCoreController.removeNode(nodeName: surfaceNode!.name);
          surfaceNode = null;
          areaPi2 = 0;
        }
      }

      selectedPoint = null;
      isDeleteMode = false;
      statusMessage = 'Point supprimé: ${measurementPoints.length} points restants';
    });
  }
  void _toggleUpdateMode() {
    setState(() {
      isUpdateMode = !isUpdateMode;
      isDeleteMode = false;

      if (isUpdateMode) {
        statusMessage = 'Sélectionnez un point à déplacer';
        updateButtonColor = Colors.red;
      } else {
        if (selectedPoint != null) {
          _updatePointColor(selectedPoint!, markerColor);
          _resetConnectedLinesColor();
          selectedPoint = null;
        }
        updateButtonColor = Colors.orange;
        statusMessage = 'Mode mise à jour désactivé';
      }
    });
  }

  void _toggleDeleteMode() {
    setState(() {
      isDeleteMode = !isDeleteMode;
      isUpdateMode = false;

      if (isDeleteMode) {
        statusMessage = 'Sélectionnez un point à supprimer';
        if (selectedPoint != null) {
          _updatePointColor(selectedPoint!, markerColor);
          _resetConnectedLinesColor();
          selectedPoint = null;
        }
      } else {
        if (selectedPoint != null) {
          _updatePointColor(selectedPoint!, markerColor);
          _resetConnectedLinesColor();
          selectedPoint = null;
        }
        statusMessage = 'Mode suppression désactivé';
      }
    });
  }
  void _highlightConnectedLines(MeasurementPoint point) {
    final index = measurementPoints.indexOf(point);
    if (index == -1) return;


    final previousIndex = (index - 1 + measurementPoints.length) % measurementPoints.length;
    final nextIndex = (index + 1) % measurementPoints.length;
    for (var line in lineSegments) {
      if (line.id == 'line_$previousIndex' || line.id == 'line_$index') {
        _updateLineColor(line, selectedMarkerColor);
      }
    }
  }
  void _updateLineColor(LineSegment line, Color color) {

    final position = line.node.position?.value ?? vector.Vector3.zero();
    final rotation = line.node.rotation?.value ?? vector.Vector4.zero();
    final cubeShape = line.node.shape as ArCoreCube;

    final updatedNode = ArCoreNode(
      name: line.node.name,
      shape: ArCoreCube(
        materials: [ArCoreMaterial(color: color)],
        size: cubeShape.size,
      ),
      position: position,
      rotation: rotation,
    );

    arCoreController.removeNode(nodeName: line.node.name);
    arCoreController.addArCoreNode(updatedNode);

    final index = lineSegments.indexWhere((l) => l.id == line.id);
    if (index != -1) {
      lineSegments[index] = LineSegment(node: updatedNode, id: line.id);
    }
  }
  void _resetConnectedLinesColor() {
    for (var line in lineSegments) {
      _updateLineColor(line, lineColor);
    }
  }

  void _updatePointColor(MeasurementPoint point, Color color) {
    final updatedNode = ArCoreNode(
      name: point.id,
      shape: ArCoreSphere(
        radius: markerSize,
        materials: [ArCoreMaterial(color: color)],
      ),
      position: point.position,
    );

    arCoreController.removeNode(nodeName: point.id);
    arCoreController.addArCoreNode(updatedNode);


    final index = measurementPoints.indexOf(point);
    if (index != -1) {
      measurementPoints[index] = MeasurementPoint(
        position: point.position,
        node: updatedNode,
        id: point.id,
      );
    }
  }

  void _calculateArea() {
    if (measurementPoints.length < 3) {
      setState(() => areaPi2 = 0);
      return;
    }

    final vertices = measurementPoints.map((p) => p.position).toList();
    final area = SurfaceUtils.calculatePolygonArea(vertices);
    setState(() => areaPi2 = area);
  }

  vector.Vector3 _projectPointOnPlane(vector.Vector3 point) {
    if (planeNormal == null || planeCenter == null) return point;
    final toPoint = point - planeCenter!;
    final distance = toPoint.dot(planeNormal!);
    return point - (planeNormal! * distance);
  }

  void _updateLines() {

    for (var line in lineSegments) {
      arCoreController.removeNode(nodeName: line.node.name);
    }
    lineSegments.clear();


    if (measurementPoints.length > 1) {
      for (int i = 0; i < measurementPoints.length; i++) {
        final start = measurementPoints[i].position;
        final end = measurementPoints[(i + 1) % measurementPoints.length].position;
        _addLine(start, end, 'line_$i');
      }
    }
  }
  void _addPoint(vector.Vector3 position) {
    final pointId = 'point_${measurementPoints.length}';
    final pointNode = ArCoreNode(
      name: pointId,
      shape: ArCoreSphere(
        radius: markerSize,
        materials: [ArCoreMaterial(color: markerColor)],
      ),
      position: position,
    );

    arCoreController.addArCoreNode(pointNode);

    setState(() {
      measurementPoints.add(MeasurementPoint(
        position: position,
        node: pointNode,
        id: pointId,
      ));
      _updateLines();
      statusMessage = 'Point ajouté: ${measurementPoints.length} points';
    });
  }

  void _cancelPointUpdate() {
    setState(() {
      if (selectedPoint != null) {
        _updatePointColor(selectedPoint!, markerColor);
      }
      isUpdateMode = false;
      isUpdateConfirmationMode = false;
      selectedPoint = null;
      updatePosition = null;
      updateButtonColor = Colors.orange;
      isPointSelected = false;
      statusMessage = 'Mise à jour annulée';
    });
  }


  void _calculateMeasurements() {
    if (measurementPoints.length < 3) {
      setState(() {
        areaPi2 = 0;
        perimeterM = 0;
      });
      return;
    }

    final vertices = measurementPoints.map((p) => p.position).toList();
    final area = SurfaceUtils.calculatePolygonArea(vertices);
    final perimeter = SurfaceUtils.calculatePerimeter(vertices);

    setState(() {
      areaPi2 = area;
      perimeterM = perimeter;
    });
  }
  void _addLine(vector.Vector3 start, vector.Vector3 end, String id, [Color? color]) {
    final direction = end - start;
    final length = direction.length;
    final midPoint = (start + end) * 0.5;

    final quaternion = vector.Quaternion.fromTwoVectors(
      vector.Vector3(1, 0, 0),
      direction.normalized(),
    );
    final rotation = vector.Vector4(
      quaternion.x,
      quaternion.y,
      quaternion.z,
      quaternion.w,
    );

    final lineNode = ArCoreNode(
      name: id,
      shape: ArCoreCube(
        materials: [ArCoreMaterial(color: color ?? lineColor)],
        size: vector.Vector3(length, lineWidth, lineWidth),
      ),
      position: midPoint,
      rotation: rotation,
    );

    arCoreController.addArCoreNode(lineNode);
    lineSegments.add(LineSegment(node: lineNode, id: id));
  }

  void _removeAllLines() {
    for (var line in lineSegments) {
      arCoreController.removeNode(nodeName: line.node.name);
    }
    lineSegments.clear();
  }
  void _deleteSelectedPoint() {
    if (selectedPoint == null) return;

    setState(() {
      _removeConnectedLines(selectedPoint!);
      final connectedIndices = [
        (measurementPoints.indexOf(selectedPoint!) - 1 + measurementPoints.length) % measurementPoints.length,
        (measurementPoints.indexOf(selectedPoint!) + 1) % measurementPoints.length
      ];

      arCoreController.removeNode(nodeName: selectedPoint!.node.name);

      measurementPoints.remove(selectedPoint);


      _removeAllLines();
      _updateLines();

      selectedPoint = null;

      if (measurementPoints.length >= 3) {
        _updateSurface();
        _calculateArea();
      } else {
        if (surfaceNode != null) {
          arCoreController.removeNode(nodeName: surfaceNode!.name);
          surfaceNode = null;
          areaPi2 = 0;
        }
      }

      statusMessage = 'Point supprimé: ${measurementPoints.length} points restants';
    });
  }

  void _removeConnectedLines(MeasurementPoint point) {
    lineSegments.removeWhere((line) {
      arCoreController.removeNode(nodeName: line.node.name);
      return true;
    });
  }

  void _updateSurface() {
    if (measurementPoints.length < 3) return;

    try {
      final points = measurementPoints.map((p) => p.position).toList();
      final adjustedPoints = SurfaceUtils.calculatePolygonVertices(points);

      vector.Vector3 center = vector.Vector3.zero();
      for (var point in adjustedPoints) {
        center += point;
      }
      center = center.scaled(1.0 / adjustedPoints.length);

      double maxWidth = 0;
      double maxHeight = 0;
      for (var point in adjustedPoints) {
        maxWidth = math.max(maxWidth, (point.x - center.x).abs() * 2);
        maxHeight = math.max(maxHeight, (point.z - center.z).abs() * 2);
      }


      arCoreController.addArCoreNode(surfaceNode!);
    } catch (e) {
      print("Erreur lors de la création de la surface: $e");
    }
  }
  void _cancelMeasurement() {
    setState(() {
      for (var point in measurementPoints) {
        arCoreController.removeNode(nodeName: point.node.name);
      }
      if (surfaceNode != null) {
        arCoreController.removeNode(nodeName: surfaceNode!.name);
        surfaceNode = null;
      }
      measurementPoints.clear();
      selectedPoint = null;
      areaPi2 = 0;
      isMarkerMode = true;
      statusMessage = 'Mesure annulée';
    });
  }
  void _completeRoom() {
    if (measurementPoints.length < 3) {
      setState(() {
        statusMessage = 'Au moins 3 points sont nécessaires pour terminer';
      });
      return;
    }

    // Automatically add a line connecting the last point to the first point
    final start = measurementPoints.last.position;
    final end = measurementPoints.first.position;
    _addLine(start, end, 'closing_line');

    _updateSurface();
    _calculateMeasurements();
    _updateLines();

    setState(() {
      isMarkerMode = false;
      isSurfaceFixed = true;
      statusMessage = 'Mesure terminée\nSurface: ${areaPi2.toStringAsFixed(2)}m²\nPérimètre: ${perimeterM.toStringAsFixed(2)}m';
    });
  }
  void _finalizePointMove(vector.Vector3 finalPosition) {
    if (selectedPoint == null) return;

    setState(() {
      final selectedIndex = measurementPoints.indexWhere((p) => p.id == selectedPoint!.id);
      if (selectedIndex == -1) return;


      final finalPointNode = ArCoreNode(
        name: selectedPoint!.id,
        shape: ArCoreSphere(
          radius: markerSize,
          materials: [ArCoreMaterial(color: markerColor)],
        ),
        position: finalPosition,
      );

      arCoreController.removeNode(nodeName: selectedPoint!.id);
      arCoreController.addArCoreNode(finalPointNode);

      measurementPoints[selectedIndex] = MeasurementPoint(
        position: finalPosition,
        node: finalPointNode,
        id: selectedPoint!.id,
      );

      _updateLines();

      if (measurementPoints.length >= 3) {
        _updateSurface();
        _calculateArea();
      }

      _exitUpdateMode();
    });
  }
  void _onArCoreViewCreated(ArCoreController controller) {
    arCoreController = controller;

    setState(() {
      statusMessage = 'AR initialisé';
    });
   arCoreController.onPlaneTap = _handlePlaneTap;
    arCoreController.onPlaneTap = (List<ArCoreHitTestResult> hits) {
      if (isMarkerMode && !isSurfaceFixed) {
        final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
        if (renderBox != null) {
          final size = renderBox.size;
          final centerX = size.width / 2;
          final centerY = size.height / 2;
          arCoreController.performHitTest(x: centerX, y: centerY).then((hits) {
            if (hits.isNotEmpty) {
              final hit = hits.first;
              final position = _projectPointOnPlane(hit.pose.translation);
              _addPoint(position);

              if (measurementPoints.length >= 3) {
                _updateSurface();
                _calculateArea();
              }
            }
          });
        }
      }
    };

    arCoreController.onPlaneDetected = (ArCorePlane plane) {
      setState(() {
        isPlaneDetected = true;
        statusMessage = 'Plan détecté';
        currentPlane = plane;

        planeNormal = vector.Vector3(
          plane.centerPose?.rotation.x ?? 0,
          plane.centerPose?.rotation.y ?? 1,
          plane.centerPose?.rotation.z ?? 0,
        ).normalized();
        planeCenter = plane.centerPose?.translation;
      });
    };

    arCoreController.onNodeTap = _onNodeTap;
  }

  Widget Reticule() {
    return Center(
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.green.withOpacity(0.3),
          border: Border.all(
            color: Colors.green,
            width: 2,
          ),
        ),
        child: Center(
          child: Container(
            width: 4,
            height: 4,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.green,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton(String label, IconData icon, Color color, VoidCallback onPressed) {
    return GestureDetector(
      onTap: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  spreadRadius: 1,
                  blurRadius: 3,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          ArCoreView(
            onArCoreViewCreated: _onArCoreViewCreated,
            enableTapRecognizer: true,
            enableUpdateListener: true,
            debug: true,
          ),
          Align(
            alignment: Alignment.center,
            child: Reticule(),
          ),
          // Status Message
          Positioned(
            top: 40,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                statusMessage,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
          // Measurements Display
          Positioned(
            top: 80,
            left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.8),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Surface: ${areaPi2.toStringAsFixed(2)}m²',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Pied carré : ${perimeterM.toStringAsFixed(2)}pi²',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF2496E0).withOpacity(0.9),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isSurfaceFixed
                        ? 'Surface fixée'
                        : 'Établir le périmètre de la pièce',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Top row: Marker and Update buttons
                      _buildActionButton(
                        'Placer un marqueur',
                        Icons.add_location,
                        isMarkerMode && !isSurfaceFixed
                            ? Colors.grey
                            : Colors.blue,
                        !isSurfaceFixed
                            ? () => setState(() => isMarkerMode = !isMarkerMode)
                            : () {},
                      ),
                      const SizedBox(width: 20),
                      _buildActionButton(
                        'Mettre à jour',
                        Icons.edit,
                        !isSurfaceFixed ? Colors.grey : Colors.blueAccent,
                        !isSurfaceFixed ? _toggleUpdateMode : () {},
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Bottom row: Cancel and Complete buttons
                      _buildActionButton(
                        'Annuler tout',
                        Icons.close,
                        !isSurfaceFixed ? Colors.grey : Colors.red,
                        !isSurfaceFixed ? _cancelMeasurement : () {},
                      ),
                      const SizedBox(width: 50),
                      _buildActionButton(
                        'Terminer',
                        Icons.check,
                        !isSurfaceFixed ? Colors.grey : Colors.red,
                        !isSurfaceFixed ? _completeRoom : () {},
                      ),
                      const SizedBox(width: 40),
                      _buildActionButton(
                        'Supprimer point',
                        Icons.delete,
                        isDeleteMode ? Colors.grey : Colors.grey,
                        selectedPoint != null && isDeleteMode
                            ? () => _deletePoint(selectedPoint!)
                            : _toggleDeleteMode,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    updateTimer?.cancel();
    arCoreController.dispose();
    super.dispose();
  }
}