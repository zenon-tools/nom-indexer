import 'package:znn_sdk_dart/znn_sdk_dart.dart';
import 'package:znn_sdk_dart/src/abi/abi.dart';
import '../services/database_service.dart';
import 'package:collection/collection.dart';

class TxData {
  final String method;
  final Map<String, String> inputs;

  TxData({this.method = '', this.inputs = const {}});
}

class NomIndexer {
  late final Zenon _node;

  late PillarInfoList _pillars;
  late SentinelInfoList _sentinels;
  late ProjectList _projects;

  NomIndexer(this._node);

  final Map<String, Abi> _contractToAbiMapping = {
    plasmaAddress.toString(): Definitions.plasma,
    pillarAddress.toString(): Definitions.pillar,
    tokenAddress.toString(): Definitions.token,
    sentinelAddress.toString(): Definitions.sentinel,
    swapAddress.toString(): Definitions.swap,
    stakeAddress.toString(): Definitions.stake,
    acceleratorAddress.toString(): Definitions.accelerator
  };

  sync() async {
    await _updateData();
    await _syncHeight();
  }

  updatePillarVotingActivity() async {
    final List<String> projectIds = [];
    final List<String> phaseIds = [];

    for (final project in _projects.list) {
      if (project.status == AcceleratorProjectStatus.voting) {
        projectIds.add(project.id.toString());
      }
      for (final phase in project.phases) {
        if (phase.status == AcceleratorProjectStatus.voting) {
          phaseIds.add(phase.id.toString());
        }
      }
    }

    await Future.forEach(_pillars.list, (PillarInfo pillar) async {
      int votes = 0;

      if (projectIds.isNotEmpty) {
        votes += await DatabaseService().getVoteCountForProjects(
            pillar.ownerAddress.toString(), projectIds);
      }
      if (phaseIds.isNotEmpty) {
        votes += await DatabaseService()
            .getVoteCountForPhases(pillar.ownerAddress.toString(), phaseIds);
      }

      final votableProposals = projectIds.length + phaseIds.length;
      final double votingActivity =
          votableProposals > 0 ? votes / votableProposals : 0;

      await DatabaseService().updatePillarVotingActivity(
          pillar.ownerAddress.toString(), votingActivity);

      print(pillar.name + ' ' + votingActivity.toString());
    });
  }

  _updateData() async {
    await _updatePillars();
    await _updateSentinels();
    await _updateProjects();
  }

  _syncHeight() async {
    while (true) {
      final dbHeight = await DatabaseService().getLatestHeight();
      final momentum = await _node.ledger.getFrontierMomentum();

      if (dbHeight >= momentum.height) {
        break;
      }

      final momentums = (await _node.ledger
              .getMomentumsByHeight(dbHeight < 2 ? 2 : dbHeight + 1, 100))
          .list;
      await Future.forEach(momentums, (Momentum m) async {
        print('Fetched momentum: ' + m.height.toString());
        await _processMomentum(m);
      });
    }
  }

  _processMomentum(Momentum? momentum) async {
    if (momentum == null) return;
    final stopwatch = Stopwatch()..start();

    if (momentum.content.isNotEmpty) {
      await _updateBalances(momentum.content);
      await _updateAccountBlocks(momentum.content);
    }

    await DatabaseService().insertMomentum(momentum);

    print(
        'processMomentum() executed in ${stopwatch.elapsed.inMilliseconds} msecs');
    stopwatch.stop();
  }

  _updateBalances(List<AccountHeader> headers) async {
    final List<AccountInfo> accountInfos =
        await Future.wait(headers.map((item) {
      return _node.ledger.getAccountInfoByAddress(item.address!);
    }).toList());

    await Future.forEach(accountInfos, (AccountInfo ai) async {
      if (ai.balanceInfoList != null) {
        await Future.forEach(ai.balanceInfoList!,
            (BalanceInfoListItem bi) async {
          if (bi.balance != null && bi.balance! >= 0) {
            await DatabaseService().insertBalance(ai.address, bi);
          }
        });
      }
    });
  }

  _updateAccountBlocks(List<AccountHeader> headers) async {
    final List<AccountBlock?> accountBlocks =
        await Future.wait(headers.map((item) {
      return _node.ledger.getAccountBlockByHash(item.hash);
    }).toList());

    await Future.forEach(accountBlocks, (AccountBlock? block) async {
      if (block != null) {
        TxData? decodedData = _tryDecodeTxData(block);

        if (block.toAddress.toString() == pillarAddress.toString() &&
            decodedData != null &&
            (decodedData.inputs['name'] ?? '').isNotEmpty &&
            (decodedData.method == 'Delegate' ||
                decodedData.method == 'Register' ||
                decodedData.method == 'RegisterLegacy' ||
                decodedData.method == 'Revoke' ||
                decodedData.method == 'UpdatePillar')) {
          // NOTE: Add pillar owner address to TX inputs to keep track of the pillar if its name changes.
          decodedData.inputs.putIfAbsent('pillarOwner',
              () => _getPillarOwnerAddress(decodedData!.inputs['name']!));
        }

        await DatabaseService().insertAccount(block);
        await DatabaseService().insertAccountBlock(block, decodedData);

        if (block.blockType == BlockTypeEnum.contractReceive.index &&
            block.pairedAccountBlock != null &&
            embeddedContractAddresses.contains(block.address)) {
          decodedData = _tryDecodeTxData(block.pairedAccountBlock!);

          if (decodedData != null) {
            await _indexEmbeddedContracts(block, decodedData);
          }
        }

        if (block.token != null) {
          await DatabaseService().insertToken(block.token!);
        }
      }
    });
  }

  _updatePillars() async {
    try {
      _pillars = await _node.embedded.pillar.getAll();
      Future.forEach(_pillars.list, (PillarInfo p) async {
        await DatabaseService().insertPillar(p);
      });
    } catch (e) {
      print(e.toString());
    }
  }

  _updateSentinels() async {
    try {
      _sentinels = await _node.embedded.sentinel.getAllActive();
      Future.forEach(_sentinels.list, (SentinelInfo s) async {
        await DatabaseService().insertSentinel(s);
      });
    } catch (e) {
      print(e.toString());
    }
  }

  _updateProjects() async {
    try {
      _projects = await _node.embedded.accelerator.getAll();
      Future.forEach(_projects.list, (Project project) async {
        await DatabaseService()
            .insertProject(project, _getVotingId(project.id));
        if (project.phases.isNotEmpty) {
          Future.forEach(project.phases, (Phase phase) async {
            await DatabaseService()
                .insertProjectPhase(phase, _getVotingId(phase.id));
          });
        }
      });
    } catch (e) {
      print(e.toString());
    }
  }

  _indexEmbeddedContracts(AccountBlock block, TxData data) async {
    final contract = block.address.toString();

    if (contract == pillarAddress.toString()) {
      await _indexEmbeddedPillarContract(block, data);
    } else if (contract == acceleratorAddress.toString()) {
      await _indexEmbeddedAcceleratorContract(block, data);
    }
  }

  _indexEmbeddedPillarContract(AccountBlock block, TxData data) async {
    if (data.method == 'Delegate' && data.inputs.isNotEmpty) {
      if (block.confirmationDetail != null) {
        await DatabaseService().updateAccountDelegate(
            block.pairedAccountBlock?.address.toString() ?? '',
            _getPillarOwnerAddress(data.inputs['name'] ?? ''),
            block.confirmationDetail!.momentumTimestamp);
      }
    } else if (data.method == 'Undelegate') {
      await DatabaseService().updateAccountDelegate(
          block.pairedAccountBlock?.address.toString() ?? '', '', 0);
    } else if (data.method == 'Register' || data.method == 'RegisterLegacy') {
      if (block.descendantBlocks.isNotEmpty) {
        final descendant = block.descendantBlocks[0];

        if (descendant.toAddress == tokenAddress &&
            _tryDecodeTxData(descendant)?.method == 'Burn') {
          if (block.confirmationDetail != null) {
            await DatabaseService().updatePillarSpawnInfo(
                _getPillarOwnerAddress(data.inputs['name'] ?? ''),
                block.confirmationDetail!.momentumTimestamp,
                descendant.amount);
          }
        }
      }
    } else if (data.method == 'Revoke') {
      await DatabaseService().setPillarAsRevoked(
          _getPillarOwnerAddress(data.inputs['name'] ?? ''));
    }
  }

  _indexEmbeddedAcceleratorContract(AccountBlock block, TxData data) async {
    if (data.method == 'VoteByName' && data.inputs.isNotEmpty) {
      if (block.confirmationDetail != null) {
        String projectId = await DatabaseService()
            .getProjectIdFromVotingId(data.inputs['id'] ?? '');
        String phaseId = '';
        if (projectId.isEmpty) {
          List<String> ids = await DatabaseService()
              .getProjectAndPhaseIdFromVotingId(data.inputs['id'] ?? '');
          if (ids.length == 2) {
            projectId = ids[0];
            phaseId = ids[1];
          }
        }

        if (data.inputs.containsKey('name') &&
            data.inputs.containsKey('id') &&
            data.inputs.containsKey('vote')) {
          final voterAddress = _getPillarOwnerAddress(data.inputs['name']!);

          await DatabaseService().insertVote(block, voterAddress, projectId,
              phaseId, data.inputs['id']!, int.parse(data.inputs['vote']!));
        }
      }
    }
  }

  TxData? _tryDecodeTxData(AccountBlock block) {
    if (block.data.isEmpty) return null;

    final toAddress = block.toAddress.toString();

    TxData decoded = TxData();

    if (embeddedContractAddresses.contains(Address.parse(toAddress))) {
      decoded = _tryDecodeFromAbi(block.data, Definitions.common);
      if (decoded.method.isNotEmpty) {
        return decoded;
      }

      decoded = _tryDecodeFromAbi(block.data, _contractToAbiMapping[toAddress]);

      if (decoded.method.toString().isEmpty) {
        print('Unable to decode ' + block.data.toString());
      } else {
        print('Decoded ' + decoded.method.toString());
      }
    }

    return decoded;
  }

  TxData _tryDecodeFromAbi(List<int> encodedData, Abi? abi) {
    if (abi != null) {
      for (final function in abi.entries) {
        if (AbiFunction.extractSignature(encodedData).toString() ==
            function.encodeSignature().toString()) {
          final Map<String, String> inputs = {};

          if (function.inputs != null && function.inputs!.isNotEmpty) {
            final List args = abi.decodeFunction(encodedData);

            for (var i = 0; i < function.inputs!.length; i++) {
              inputs[function.inputs![i].name!] =
                  args.length > i ? args[i].toString() : '';
            }
          }

          return TxData(method: function.name!, inputs: inputs);
        }
      }
    }
    return TxData();
  }

  String _getVotingId(Hash projectOrPhaseId) {
    // TODO: Find a better way to map the project or phase ID with the voting ID.
    List<int> encoded = Definitions.accelerator
        .encodeFunction('VoteByName', [projectOrPhaseId.getBytes(), '', 0]);
    List decoded = Definitions.accelerator.decodeFunction(encoded);
    return decoded[0]?.toString() ?? '';
  }

  String _getPillarOwnerAddress(String name) {
    return (_pillars.list.firstWhereOrNull((i) => i.name == (name)))
            ?.ownerAddress
            .toString() ??
        '';
  }
}
