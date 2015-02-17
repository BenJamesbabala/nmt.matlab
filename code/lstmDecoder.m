function [candidates, candScores] = lstmDecoder(model, data, params)
%%%
%
% Decode from an LSTM model.
%   stackSize: the maximum number of translations we want to get.
% Output:
%   - candidates: list of candidates
%   - candScores: score of the corresponding candidates (stackSize * batchSize)
%
% Thang Luong @ 2015, <lmthang@stanford.edu>
% Hieu Pham @ 2015, <hyhieu@cs.stanford.edu>
%
%%%
  beamSize = params.beamSize;
  stackSize = params.stackSize;
  
  input = data.input;
  inputMask = data.inputMask; 
  srcMaxLen = data.srcMaxLen;
  %printSent(2, input(1, 1:srcMaxLen), params.vocab, 'src 1: ');
  %printSent(2, input(1, srcMaxLen:end), params.vocab, 'tgt 1: ');
  %printSent(2, input(end, 1:srcMaxLen), params.vocab, 'src end: ');
  
  %% init
  batchSize = size(input, 1);
  zeroState = zeroMatrix([params.lstmSize, batchSize], params.isGPU, params.dataType);
  fprintf(2, '# Decoding batch of %d sents, srcMaxLen=%d, %s\n', batchSize, srcMaxLen, datestr(now));
  fprintf(params.logId, '# Decoding batch of %d sents, srcMaxLen=%d, %s\n', batchSize, srcMaxLen, datestr(now));
  
  %%%%%%%%%%%%
  %% encode %%
  %%%%%%%%%%%%
  lstm = cell(params.numLayers, 1); % lstm can be over written, as we do not need to backprop
%   accm_lstm = cell(params.numLayers, 1); % accumulate c_t and h_t over time
%   for ll=1:params.numLayers % layer
%     accm_lstm{ll}.c_t = zeroState;
%     accm_lstm{ll}.h_t = zeroState;
%   end

  W = model.W_src;
  for t=1:srcMaxLen % time
    maskedIds = find(~inputMask(:, t)); % curBatchSize * 1
    if t==srcMaxLen % due to implementation in lstmCostGrad, we have to switch to W_tgt here. THIS IS VERY IMPORTANT!
      W = model.W_tgt;
    end
    for ll=1:params.numLayers % layer
      % previous-time input
      if t==1 % first time step
        h_t_1 = zeroState;
        c_t_1 = zeroState;
      else
        h_t_1 = lstm{ll}.h_t; 
        c_t_1 = lstm{ll}.c_t;
      end

      % current-time input
      if ll==1 % first layer
        x_t = model.W_emb(:, input(:, t));
        %params.vocab(input(:, t))
      else % subsequent layer, use the previous-layer hidden state
        x_t = lstm{ll-1}.h_t;
      end
     
      % masking
      x_t(:, maskedIds) = 0; 
      h_t_1(:, maskedIds) = 0;
      c_t_1(:, maskedIds) = 0;

      % lstm cell
      lstm{ll} = lstmUnit(W{ll}, x_t, h_t_1, c_t_1, params, 1);

      % accumulate
      if params.assert
        assert(gather(sum(sum(abs(lstm{ll}.c_t(:, maskedIds)))))<1e-5);
        assert(gather(sum(sum(abs(lstm{ll}.h_t(:, maskedIds)))))<1e-5);
      end
%       accm_lstm{ll}.c_t = accm_lstm{ll}.c_t + lstm{ll}.c_t;
%       accm_lstm{ll}.h_t = accm_lstm{ll}.h_t + lstm{ll}.h_t;
    end
  end
  
  %%%%%%%%%%%%
  %% decode %%
  %%%%%%%%%%%%
  startTime = clock;
  maxLen = floor(srcMaxLen*1.5);
  sentIndices = data.startId:(data.startId+batchSize-1);
  [candidates, candScores] = decodeBatch(model, params, lstm, maxLen, beamSize, stackSize, batchSize, sentIndices);
  endTime = clock;
  timeElapsed = etime(endTime, startTime);
  fprintf(2, '  Done, maxLen=%d, speed %f sents/s, time %.0fs, %s\n', maxLen, batchSize/timeElapsed, timeElapsed, datestr(now));
  fprintf(params.logId, '  Done, maxLen=%d, speed %f sents/s, time %.0fs, %s\n', maxLen, batchSize/timeElapsed, timeElapsed, datestr(now));
end

%%%
%
% Beam decoder from an LSTM model, works for multiple sentences
%
% Input:
%   - encoded vector of the source sentences
%   - maximum length willing to go
%   - beamSize
%   - stackSize: maximum number of translations collected for one example
%
%%%
function [candidates, candScores] = decodeBatch(model, params, lstmStart, maxLen, beamSize, stackSize, batchSize, originalSentIndices)
  numLayers = params.numLayers;
  
  candidates = cell(batchSize, 1);
  candScores = -1e10*oneMatrix([stackSize, batchSize], params.isGPU, params.dataType); % set to a very small value
  numDecoded = zeros(batchSize, 1);
  for ii=1:batchSize
    candidates{ii} = cell(stackSize, 1);
  end
  
  %% first prediction
  [scores, words] = nextBeamStep(model, lstmStart{numLayers}.h_t, beamSize, params); % scores, words: beamSize * batchSize
  
  %% matrix dimension note
  % note that we order matrices in the following dimension: n * (batchSize*beamSize)
  % columns correspond to the 1st sent go first, then the 2nd one, until the batchSize-th sent.
  sentIndices = repmat(1:batchSize, beamSize, 1);
  sentIndices = sentIndices(:)'; % 1 ... 1, 2 ... 2, ...., batchSize ... batchSize . 1 * (beamSize*batchSize)
  
  %% init beam
  beamScores = scores(:)'; % 1 * (beamSize*batchSize)
  beamHistory = zeroMatrix([maxLen, batchSize*beamSize], params.isGPU, params.dataType); % maxLen * (batchSize*beamSize) 
  beamHistory(1, :) = words(:); % words for sent 1 go together, then sent 2, ...
  beamStates = cell(numLayers, 1);
  for ll=1:numLayers % lstmSize * (batchSize*beamSize)
    beamStates{ll}.c_t = reshape(repmat(lstmStart{ll}.c_t, beamSize, 1),  params.lstmSize, batchSize*beamSize); 
    beamStates{ll}.h_t = reshape(repmat(lstmStart{ll}.h_t, beamSize, 1),  params.lstmSize, batchSize*beamSize); 
  end
  
  decodeCompleteCount = 0; % count how many sentences we have completed collecting the translations
  nextWords = zeroMatrix([1, batchSize*beamSize], params.isGPU, params.dataType);
  beamIndices = zeroMatrix([1, batchSize*beamSize], params.isGPU, params.dataType);
  for sentPos = 1 : maxLen
    % compute next lstm hidden states
    words = beamHistory(sentPos, :);
    for ll = 1 : numLayers
      % current input
      if ll == 1
        x_t = model.W_emb(:, words);
      else
        x_t = beamStates{ll-1}.h_t;
      end
      % previous input
      h_t_1 = beamStates{ll}.h_t;
      c_t_1 = beamStates{ll}.c_t;

      beamStates{ll} = lstmUnit(model.W_tgt{ll}, x_t, h_t_1, c_t_1, params, 1);
    end
    
    % predict the next word
    [allBestScores, allBestWords] = nextBeamStep(model, beamStates{numLayers}.h_t, beamSize, params); % beamSize * (beamSize*batchSize)
    
%     beamScores
%     params.vocab(beamHistory(1:sentPos, :))
%     params.vocab(allBestWords)

    % use previous beamScores, 1 * (beamSize*batchSize), update along the first dimentions
    allBestScores = bsxfun(@plus, allBestScores, beamScores);
    allBestScores = reshape(allBestScores, [beamSize*beamSize, batchSize]);
    allBestWords = reshape(allBestWords, [beamSize*beamSize, batchSize]);
    
    % for each sent, select the best beamSize candidates, out of beamSize^2 ones
    [allBestScores, indices] = sort(allBestScores, 'descend'); % beamSize^2 * batchSize
    
    %% build new beam
    for sentId=1:batchSize
      startId = (sentId-1)*beamSize+1;
      endId = sentId*beamSize;
      rowIndices = indices(:, sentId)';
      bestWords = allBestWords(rowIndices, sentId);
      
      % nonEosIndices: get the top beamSize words that are not eos
      nonEosIndices = find(bestWords~=params.tgtEos, beamSize);
      nextWords(startId:endId) = bestWords(nonEosIndices);
      
      % update beam
      beamIndices(startId:endId) = floor((rowIndices(nonEosIndices)-1)/beamSize) + 1;
      
      % update scores
      beamScores(startId:endId) = allBestScores(nonEosIndices, sentId);
      
      % store translations
      eosIndices = find(bestWords(1:nonEosIndices(end))==params.tgtEos); % get words that are eos and ranked before the last hypothesis in the next beam
      if ~isempty(eosIndices) && sentPos>2 % we don't want to start recording very short translations
        numTranslations = length(eosIndices);
        eosBeamIndices = floor((rowIndices(eosIndices)-1)/beamSize) + 1;
        translations = beamHistory(1:sentPos, (sentId-1)*beamSize + eosBeamIndices);
        transScores = allBestScores(eosIndices, sentId);
        for ii=1:numTranslations
          if numDecoded(sentId)<stackSize % haven't collected enough translations
            numDecoded(sentId) = numDecoded(sentId) + 1;
            candidates{sentId}{numDecoded(sentId)} = [translations(:, ii); params.tgtEos];
            candScores(numDecoded(sentId), sentId) = transScores(ii);

            %printSent(2, translations(:, ii), params.vocab, ['  trans sent ' num2str(originalSentIndices(sentId)) ', ' num2str(transScores(ii)), ': ']);
            if numDecoded(sentId)==stackSize % done for sentId
              decodeCompleteCount = decodeCompleteCount + 1;
              break;
            end
          end
        end
      end
    end
    
    %% update history
    % overwrite previous history
    colIndices = (sentIndices-1)*beamSize + beamIndices;
    beamHistory(1:sentPos, :) = beamHistory(1:sentPos, colIndices); 
    beamHistory(sentPos+1, :) = nextWords;
    
    %% update lstm states
    for ll=1:numLayers
      % lstmSize * (batchSize*beamSize): h_t and c_t vectors of each sent are arranged near each other
      beamStates{ll}.c_t = beamStates{ll}.c_t(:, colIndices); 
      beamStates{ll}.h_t = beamStates{ll}.h_t(:, colIndices);
    end
    
    if decodeCompleteCount==batchSize % done decoding the entire batch
      break;
    end
  end
  
  for sentId=1:batchSize
    if numDecoded(sentId) == 0 % no translations found, output all we have in the beam
      fprintf(2, '  ! Sent %d: no translations end in eos\n', originalSentIndices(sentId));
      for bb = 1:beamSize
        eosIndex = (sentId-1)*beamSize + bb;
        numDecoded(sentId) = numDecoded(sentId) + 1;
        candidates{sentId}{numDecoded(sentId)} = [beamHistory(1:maxLen, eosIndex); params.tgtEos]; % append eos at the end
        candScores(numDecoded(sentId), sentId) = beamScores(eosIndex);
      end
    end
    candidates{sentId}(numDecoded(sentId)+1:end) = [];
  end
end


function [bestLogProbs, bestWords] = nextBeamStep(model, h, beamSize, params)
  % return bestLogProbs, bestWords of sizes beamSize * curBatchSize
  [logProbs] = softmaxDecode(model.W_soft*h);
  [sortedLogProbs, sortedWords] = sort(logProbs, 'descend');
  bestWords = sortedWords(1:beamSize, :);
  bestLogProbs = sortedLogProbs(1:beamSize, :);
  
  % penalize unks
  if params.unkPenalty>0 
    bestLogProbs = bestLogProbs - params.unkPenalty*(bestWords==params.unkId);
  end
  
  % length reward
  if params.lengthReward>0
    bestLogProbs = bestLogProbs + params.lengthReward;
  end
end

function [logProbs] = softmaxDecode(scores)
%% only compute logProbs
  mx = max(scores);
  scores = bsxfun(@minus, scores, mx); % subtract max elements 
  logProbs = bsxfun(@minus, scores, log(sum(exp(scores))));
end

%  show_beam(beam, beam_size, params);
% function [] = showBeam(beam, beam_size, batchSize, params)
%   fprintf(2, 'current beam state:\n');
%   for bb=1:beam_size
%     for jj=1:batchSize
%       fprintf(2, 'hypothesis beam %d, example %d\n', bb, jj);
%       for ii=1:length(beam.hists{bb}(jj, :))
%         fprintf(2, '%s ', params.vocab{beam.hists{bb}(jj, ii)});
%       end
%       fprintf(2, ' -> %f\n', beam.scores(bb, jj));
%       fprintf(2, '===================\n');
%     end
%   end
%   fprintf(2, 'end_beam ================================================== end_beam\n');
% end

%     %% update scores
%     beamScores = allBestScores(1:beamSize, :);
%     beamScores = beamScores(:)';
%     
%     %% update history
%     % find out which beams these beamSize*batchSize derivations came from
%     rowIndices = indices(1:beamSize, :); % beamSize * batchSize
%     rowIndices = rowIndices(:)';
%     beamIndices = floor((rowIndices-1)/beamSize) + 1; 
%     % figure out best next words
%     nextWords = allBestWords(sub2ind(size(allBestWords), rowIndices, sentIndices))';
%     % overwrite previous history
%     colIndices = (sentIndices-1)*beamSize + beamIndices;
%     beamHistory(1:sentPos, :) = beamHistory(1:sentPos, colIndices); 
%     beamHistory(sentPos+1, :) = nextWords;
%     
%     %% update lstm states
%     for ll=1:numLayers
%       % lstmSize * (batchSize*beamSize): h_t and c_t vectors of each sent are arranged near each other
%       beamStates{ll}.c_t = beamStates{ll}.c_t(:, colIndices); 
%       beamStates{ll}.h_t = beamStates{ll}.h_t(:, colIndices);
%     end
%  
%     %% find out if some derivations reach eos
%     eosIndices = find(nextWords == params.tgtEos);
%     for ii=1:length(eosIndices)
%       eosIndex = eosIndices(ii);
%       sentId = sentIndices(eosIndex);
%       
%       if numDecoded(sentId)<stackSize % haven't collected enough translations
%         numDecoded(sentId) = numDecoded(sentId) + 1;
%         candidates{sentId}{numDecoded(sentId)} = beamHistory(1:sentPos+1, eosIndex);
%         candScores(numDecoded(sentId), sentId) = beamScores(eosIndex);
%         
%         beamScores(eosIndex) = -1e10; % make the beam score small so that it won't make into the candidate list again
% 
%         if numDecoded(sentId)==stackSize % done for sentId
%           decodeCompleteCount = decodeCompleteCount + 1;
%         end
%       end
%     end

