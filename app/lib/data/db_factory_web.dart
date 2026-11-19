import 'package:sembast/sembast.dart';
import 'package:sembast_web/sembast_web.dart';

Future<Database> openAppDb() => databaseFactoryWeb.openDatabase('cartertag_connect');
