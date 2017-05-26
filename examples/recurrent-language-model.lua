require 'paths'
require 'rnn'
require 'optim'
local dl = require 'dataload'

--[[ command line arguments ]]--
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train a Language Model on PennTreeBank dataset using RNN or LSTM or GRU')
cmd:text('Example:')
cmd:text('th recurrent-language-model.lua --cuda --device 2 --progress --cutoff 4 --seqlen 10')
cmd:text("th recurrent-language-model.lua --progress --cuda --lstm --seqlen 20 --hiddensize '{200,200}' --batchsize 20 --startlr 1 --cutoff 5 --maxepoch 13 --schedule '{[5]=0.5,[6]=0.25,[7]=0.125,[8]=0.0625,[9]=0.03125,[10]=0.015625,[11]=0.0078125,[12]=0.00390625}'")
cmd:text("th recurrent-language-model.lua --progress --cuda --lstm --seqlen 35 --uniform 0.04 --hiddensize '{1500,1500}' --batchsize 20 --startlr 1 --cutoff 10 --maxepoch 50 --schedule '{[15]=0.87,[16]=0.76,[17]=0.66,[18]=0.54,[19]=0.43,[20]=0.32,[21]=0.21,[22]=0.10}' -dropout 0.65")
cmd:text('Options:')
-- training
cmd:option('--startlr', 0.05, 'learning rate at t=0')
cmd:option('--minlr', 0.00001, 'minimum learning rate')
cmd:option('--saturate', 400, 'epoch at which linear decayed LR will reach minlr')
cmd:option('--schedule', '', 'learning rate schedule. e.g. {[5] = 0.004, [6] = 0.001}')
cmd:option('--momentum', 0.9, 'momentum')
cmd:option('--adam', false, 'use ADAM instead of SGD as optimizer')
cmd:option('--adamconfig', '{0, 0.999}', 'ADAM hyperparameters beta1 and beta2')
cmd:option('--maxnormout', -1, 'max l2-norm of each layer\'s output neuron weights')
cmd:option('--cutoff', -1, 'max l2-norm of concatenation of all gradParam tensors')
cmd:option('--batchSize', 32, 'number of examples per batch')
cmd:option('--cuda', false, 'use CUDA')
cmd:option('--device', 1, 'sets the device (GPU) to use')
cmd:option('--maxepoch', 1000, 'maximum number of epochs to run')
cmd:option('--earlystop', 50, 'maximum number of epochs to wait to find a better local minima for early-stopping')
cmd:option('--progress', false, 'print progress bar')
cmd:option('--silent', false, 'don\'t print anything to stdout')
cmd:option('--uniform', 0.1, 'initialize parameters using uniform distribution between -uniform and uniform. -1 means default initialization')
-- rnn layer
cmd:option('--lstm', false, 'use Long Short Term Memory (nn.LSTM instead of nn.LinearRNN)')
cmd:option('--bn', false, 'use batch normalization. Only supported with --lstm')
cmd:option('--gru', false, 'use Gated Recurrent Units (nn.RecGRU instead of nn.LinearRNN)')
cmd:option('--mfru', false, 'use Multi-function Recurrent Unit (nn.MuFuRu instead of nn.LinearRNN)')
cmd:option('--seqlen', 5, 'sequence length : back-propagate through time (BPTT) for this many time-steps')
cmd:option('--inputsize', -1, 'size of lookup table embeddings. -1 defaults to hiddensize[1]')
cmd:option('--hiddensize', '{200}', 'number of hidden units used at output of each recurrent layer. When more than one is specified, RNN/LSTMs/GRUs are stacked')
cmd:option('--dropout', 0, 'apply dropout with this probability after each rnn layer. dropout <= 0 disables it.')
-- data
cmd:option('--batchsize', 32, 'number of examples per batch')
cmd:option('--trainsize', -1, 'number of train examples seen between each epoch')
cmd:option('--validsize', -1, 'number of valid examples used for early stopping and cross-validation')
cmd:option('--savepath', paths.concat(dl.SAVE_PATH, 'rnnlm'), 'path to directory where experiment log (includes model) will be saved')
cmd:option('--id', '', 'id string of this experiment (used to name output file) (defaults to a unique id)')

cmd:text()
local opt = cmd:parse(arg or {})
opt.version = 2
opt.hiddensize = loadstring(" return "..opt.hiddensize)()
opt.schedule = loadstring(" return "..opt.schedule)()
opt.adamconfig = loadstring(" return "..opt.adamconfig)()
opt.inputsize = opt.inputsize == -1 and opt.hiddensize[1] or opt.inputsize
if not opt.silent then
   table.print(opt)
end
opt.id = opt.id == '' and ('ptb' .. ':' .. dl.uniqueid()) or opt.id

if opt.cuda then
   require 'cunn'
   cutorch.setDevice(opt.device)
end

--[[ data set ]]--

local trainset, validset, testset = dl.loadPTB({opt.batchsize,1,1})
if not opt.silent then
   print("Vocabulary size : "..#trainset.ivocab)
   print("Train set split into "..opt.batchsize.." sequences of length "..trainset:size())
end

--[[ language model ]]--

local lm = nn.Sequential()

-- input layer (i.e. word embedding space)
local lookup = nn.LookupTable(#trainset.ivocab, opt.inputsize)
lookup.maxOutNorm = -1 -- prevent weird maxnormout behaviour
lm:add(lookup) -- input is seqlen x batchsize
if opt.dropout > 0 then
   lm:add(nn.Dropout(opt.dropout))
end

-- rnn layers
local stepmodule = nn.Sequential() -- applied at each time-step
local inputsize = opt.inputsize
for i,hiddensize in ipairs(opt.hiddensize) do
   local rnn

   if opt.gru then -- Gated Recurrent Units
      rnn = nn.RecGRU(inputsize, hiddensize)
   elseif opt.lstm then -- Long Short Term Memory units
      rnn = nn.RecLSTM(inputsize, hiddensize)
   elseif opt.mfru then -- Multi Function Recurrent Unit
      rnn = nn.MuFuRu(inputsize, hiddensize)
   elseif i == 1 then -- simple recurrent neural network
      local rm =  nn.Sequential() -- input is {x[t], h[t-1]}
         :add(nn.ParallelTable()
            :add(nn.Identity()) -- input layer
            :add(nn.Linear(hiddensize, hiddensize))) -- recurrent layer
         :add(nn.CAddTable()) -- merge
         :add(nn.Sigmoid()) -- transfer
      rnn = nn.Recurrence(rm, hiddensize, 1)
   else
      rnn = nn.LinearRNN(hiddensize, hiddensize)
   end

   stepmodule:add(rnn)

   if opt.dropout > 0 then
      stepmodule:add(nn.Dropout(opt.dropout))
   end

   inputsize = hiddensize
end

-- output layer
stepmodule:add(nn.Linear(inputsize, #trainset.ivocab))
stepmodule:add(nn.LogSoftMax())

-- encapsulate stepmodule into a Sequencer
lm:add(nn.Sequencer(stepmodule))

-- remember previous state between batches
lm:remember((opt.lstm or opt.gru or opt.mfru) and 'both' or 'eval')

if not opt.silent then
   print"Language Model:"
   print(lm)
end

if opt.uniform > 0 then
   for k,param in ipairs(lm:parameters()) do
      param:uniform(-opt.uniform, opt.uniform)
   end
end

--[[ loss function ]]--

-- target is also seqlen x batchsize.
local targetmodule = opt.cuda and nn.Convert() or nn.Identity()
-- NLL is applied to each time-step
local criterion = nn.SequencerCriterion(nn.ClassNLLCriterion())

--[[ CUDA ]]--

if opt.cuda then
   lm:cuda()
   criterion:cuda()
   targetmodule:cuda()
end

-- make sure to call getParameters before sharedClone
local params, grad_params = lm:getParameters()

--[[ experiment log ]]--

-- is saved to file every time a new validation minima is found
local xplog = {}
xplog.opt = opt -- save all hyper-parameters and such
xplog.dataset = 'PennTreeBank'
xplog.vocab = trainset.vocab
-- will only serialize params
xplog.model = lm:sharedClone()
xplog.criterion = criterion
xplog.targetmodule = targetmodule
-- keep a log of NLL for each epoch
xplog.trainppl = {}
xplog.valppl = {}
-- will be used for early-stopping
xplog.minvalppl = 99999999
xplog.epoch = 0

local adamconfig = {
   beta1 = opt.adamconfig[1],
   beta2 = opt.adamconfig[2],
}

local ntrial = 0
paths.mkdir(opt.savepath)

local epoch = 1
opt.lr = opt.startlr
opt.trainsize = opt.trainsize == -1 and trainset:size() or opt.trainsize
opt.validsize = opt.validsize == -1 and validset:size() or opt.validsize
while opt.maxepoch <= 0 or epoch <= opt.maxepoch do
   print("")
   print("Epoch #"..epoch.." :")

   -- 1. training
   sgdconfig = {
      learningRate = opt.lr,
      momentum = opt.momentum
   }

   local a = torch.Timer()
   lm:training()
   local sumErr = 0
   -- local sumErr = 0
   for i, inputs, targets in trainset:subiter(opt.seqlen, opt.trainsize) do
      local curTargets = targetmodule:forward(targets)
      local curInputs = inputs

      local function feval(x)
         if x ~= params then
            params:copy(x)
         end
         grad_params:zero()

         -- forward
         local outputs = lm:forward(curInputs)
         local err = criterion:forward(outputs, curTargets)
         sumErr = sumErr + err

         -- backward
         local gradOutputs = criterion:backward(outputs, curTargets)
         lm:zeroGradParameters()
         lm:backward(curInputs, gradOutputs)

         -- gradient clipping
         if opt.cutoff > 0 then
            local norm = lm:gradParamClip(opt.cutoff) -- affects gradParams
            opt.meanNorm = opt.meanNorm and (opt.meanNorm*0.9 + norm*0.1) or norm
         end

         return err, grad_params
      end

      if opt.adam then
         local _, loss = optim.adam(feval, params, adamconfig)
      else
         local _, loss = optim.sgd(feval, params, sgdconfig)
      end

      if opt.progress then
         xlua.progress(math.min(i + opt.seqlen, opt.trainsize), opt.trainsize)
      end

      if i % 1000 == 0 then
         collectgarbage()
      end

   end

   -- learning rate decay
   if opt.schedule then
      opt.lr = opt.schedule[epoch] or opt.lr
   else
      opt.lr = opt.lr + (opt.minlr - opt.startlr)/opt.saturate
   end
   opt.lr = math.max(opt.minlr, opt.lr)

   if not opt.silent then
      print("learning rate", opt.lr)
      if opt.meanNorm then
         print("mean gradParam norm", opt.meanNorm)
      end
   end

   if cutorch then cutorch.synchronize() end
   local speed = a:time().real/opt.trainsize
   print(string.format("Speed : %f sec/batch ", speed))

   local ppl = torch.exp(sumErr/opt.trainsize)
   print("Training PPL : "..ppl)

   xplog.trainppl[epoch] = ppl

   -- 2. cross-validation

   lm:evaluate()
   local sumErr = 0
   for i, inputs, targets in validset:subiter(opt.seqlen, opt.validsize) do
      targets = targetmodule:forward(targets)
      local outputs = lm:forward(inputs)
      local err = criterion:forward(outputs, targets)
      sumErr = sumErr + err
   end

   local ppl = torch.exp(sumErr/opt.validsize)
   -- Perplexity = exp( sum ( NLL ) / #w)
   print("Validation PPL : "..ppl)

   xplog.valppl[epoch] = ppl
   ntrial = ntrial + 1

   -- early-stopping
   if ppl < xplog.minvalppl then
      -- save best version of model
      xplog.minvalppl = ppl
      xplog.epoch = epoch
      local filename = paths.concat(opt.savepath, opt.id..'.t7')
      print("Found new minima. Saving to "..filename)
      torch.save(filename, xplog)
      ntrial = 0
   elseif ntrial >= opt.earlystop then
      print("No new minima found after "..ntrial.." epochs.")
      print("Stopping experiment.")
      break
   end

   collectgarbage()
   epoch = epoch + 1
end
print("Evaluate model using : ")
print("th scripts/evaluate-rnnlm.lua --xplogpath "..paths.concat(opt.savepath, opt.id..'.t7')..(opt.cuda and ' --cuda' or ''))
