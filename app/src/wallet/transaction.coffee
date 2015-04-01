ValidationModes =
    PIN: 0x01
    KEYCARD: 0x02
    SECURE_SCREEN: 0x03

Errors = @ledger.errors

Amount = ledger.Amount

@ledger.wallet ?= {}

###
@example Usage
  amount = ledger.Amount.fromBtc("1.234")
  fee = ledger.Amount.fromBtc("0.0001")
  recipientAddress = "1DR6p2UVfu1m6mCU8hyvh5r6ix3dJEPMX7"
  ledger.wallet.Transaction.createAndPrepareTransaction(amount, fees, recipientAddress, inputsAccounts, changeAccount).then (tx) =>
    console.log("Prepared tx :", tx)
###
class ledger.wallet.Transaction
  Transaction = @

  #
  @ValidationModes: ValidationModes
  #
  @DEFAULT_FEES: Amount.fromBits(50)
  #
  @MINIMUM_CONFIRMATIONS: 1
  #
  @MINIMUM_OUTPUT_VALUE: Amount.fromSatoshi(5430)

  # @property [ledger.Amount]
  amount: undefined
  # @property [ledger.Amount]
  fees: @DEFAULT_FEES
  # @property [String]
  recipientAddress: undefined
  # @property [Array<Object>]
  inputs: undefined
  # @property [String]
  changePath: undefined
  # @property [String]
  hash: undefined
  # @property [String]
  authorizationPaired: undefined


  # @property [Boolean]
  _isValidated: no
  # @property [Object]
  _resumeData: undefined
  # @property [Integer]
  _validationMode: undefined
  # @property [Array<Object>]
  _btInputs: undefined
  # @property [Array<Object>]
  _btcAssociatedKeyPath: undefined
  # @property [Object]
  _transaction: undefined

  # @param [ledger.dongle.Dongle] dongle
  # @param [ledger.Amount] amount
  # @param [ledger.Amount] fees
  # @param [String] recipientAddress
  constructor: (@dongle, @amount, @fees, @recipientAddress, @inputs, @changePath) ->
    @_btInputs = []
    @_btcAssociatedKeyPath = []
    for input in inputs
      splitTransaction = @dongle.splitTransaction(input)
      @_btInputs.push [splitTransaction, input.output_index]
      @_btcAssociatedKeyPath.push input.paths[0]

  # @return [Boolean]
  isValidated: () -> @_isValidated

  # @return [String]
  getSignedTransaction: () -> @_transaction

  # @return [Integer]
  getValidationMode: () -> @_validationMode

  # @return [ledger.Amount]
  getAmount: () -> @amount

  # @return [String]
  getRecipientAddress: () -> @receiverAddress

  # @param [String] hash
  setHash: (hash) -> @hash = hash

  # @param [Array<Object>] inputs
  # @param [String] changePath
  # @param [Function] callback
  # @return [CompletionClosure]
  prepare: (callback=undefined) ->
    if not @amount? or not @fees? or not @recipientAddress?
      Errors.throw('Transaction must me initialized before preparation')
    completion = new CompletionClosure(callback)
    @dongle.createPaymentTransaction(@_btInputs, @_btcAssociatedKeyPath, @changePath, @recipientAddress, @amount, @fees)
    .then (@_resumeData) =>
      @_validationMode = @_resumeData.authorizationRequired
      @authorizationPaired = @_resumeData.authorizationPaired
      completion.success()
    .fail (error) =>
      completion.failure(Errors.new(Errors.SignatureError))
    .done()
    completion.readonly()
  
  # @param [String] validationKey 4 chars ASCII encoded
  # @param [Function] callback
  # @return [CompletionClosure]
  validateWithPinCode: (validationPinCode, callback=undefined) -> @_validate(validationPinCode, callback)

  # @param [String] validationKey 4 chars ASCII encoded
  # @param [Function] callback
  # @return [CompletionClosure]
  validateWithKeycard: (validationKey, callback = null) -> @_validate(("0#{char}" for char in validationKey).join(''), callback)

  # @param [String] validationKey 4 chars ASCII encoded
  # @param [Function] callback
  # @return [CompletionClosure]
  _validate: (validationKey, callback=undefined) ->
    if not @_resumeData? or not @_validationMode?
      Errors.throw('Transaction must me prepared before validation')
    completion = new CompletionClosure(callback)
    @dongle.createPaymentTransaction(
      @_btInputs, @_btcAssociatedKeyPath, @changePath, @recipientAddress, @amount, @fees,
      undefined, # Default lockTime
      undefined, # Default sigHash
      validationKey,
      resumeData
    )
    .then (@_transaction) =>
      @_isValidated = yes
      _.defer => completion.success()
    .fail (error) =>
      _.defer => completion.failure(Errors.new(Errors.SignatureError, error))
    .done()
    completion.readonly()

  # Retrieve information that need to be confirmed by the user.
  # @return [Object]
  #   @option [Integer] validationMode
  #   @option [Object, undefined] amount
  #     @option [String] text
  #     @option [Array<Integer>] indexes
  #   @option [Object] recipientsAddress
  #     @option [String] text
  #     @option [Array<Integer>] indexes
  #   @option [String] validationCharacters
  #   @option [Boolean] needsAmountValidation
  getValidationDetails: ->
    details =
      validationMode: @_validationMode
      recipientsAddress:
        text: @recipientAddress
        indexes: @_resumeData.indexesKeyCard.match(/../g)
      validationCharacters: (@recipientAddress[index] for index in @_resumeData.indexesKeyCard.match(/../g))
      needsAmountValidation: false

    # ~> 1.4.13 need validation on amount
    if @dongle.getIntFirmwareVersion() < @dongle.Firmware.V1_4_13
      stringifiedAmount = @amount.toString()
      stringifiedAmount = _.str.lpad(stringifiedAmount, 9, '0')
      # Split amount in integer and decimal parts
      integerPart = stringifiedAmount.substr(0, stringifiedAmount.length - 8)
      decimalPart = stringifiedAmount.substr(stringifiedAmount.length - 8)
      # Prepend to validationCharacters first digit of integer part,
      # and 3 first digit of decimal part only if not empty.
      amountChars = [integerPart.charAt(integerPart.length - 1)]
      if decimalPart isnt "00000000"
        amountChars.concat decimalPart.substring(0,3).split('')
      details.validationCharacters = amountChars.concat(details.validationCharacters)
      # Compute amount indexes
      firstIdx = integerPart.length - 1
      lastIdx = if decimalPart is "00000000" then firstIdx else firstIdx+3
      detail.amount =
        text: stringifiedAmount
        indexes: [firstIdx..lastIdx]
      details.needsAmountValidation = true

    return details

  ###
  Creates a new transaction asynchronously. The created transaction will only be initialized (i.e. it will only retrieve
  a sufficient number of input to perform the transaction)

  @param {ledger.Amount} amount The amount to send (expressed in satoshi)
  @param {ledger.Amount} fees The miner fees (expressed in satoshi)
  @param {String} address The recipient address
  @param {Array<String>} inputsPath The paths of the addresses to use in order to perform the transaction
  @param {String} changePath The path to use for the change
  @option [Function] callback The callback called once the transaction is created
  @return [CompletionClosure] A closure
  ###
  @create: ({amount, fees, address, inputsPath, changePath}, callback = null) ->
    completion = new CompletionClosure(callback)
    return completion.failure(Errors.new(Errors.DustTransaction)) && completion.readonly() if amount.lte(Transaction.MINIMUM_OUTPUT_VALUE)
    return completion.failure(Errors.new(Errors.NotEnoughFunds)) && completion.readonly() unless inputsPath?.length
    requiredAmount = amount.add(fees)

    ledger.api.UnspentOutputsRestClient.instance.getUnspentOutputsFromPaths inputsPath, (outputs, error) ->
      return completion.failure(Errors.new(Errors.NetworkError, error)) if error?
      # Collect each valid outputs and sort them by desired priority
      validOutputs = _(output for output in outputs when output.paths.length > 0).sortBy (output) ->  -output['confirmatons']
      return completion.failure(Errors.new(Errors.NotEnoughFunds)) if validOutputs.length == 0
      finalOutputs = []
      collectedAmount = new Amount()
      hadNetworkFailure = no

      # For each valid outputs we try to get its raw transaction.
      _.async.each validOutputs, (output, done, hasNext) =>
        ledger.api.TransactionsRestClient.instance.getRawTransaction output.transaction_hash, (rawTransaction, error) ->
          if error?
            hadNetworkFailure = yes
            return done()

          output.raw = rawTransaction
          finalOutputs.push(output)
          collectedAmount = collectedAmount.add(Amount.fromSatoshi(output.value))

          if collectedAmount.gte(requiredAmount)
            changeAmount = collectedAmount.subtract(requiredAmount)
            fees = fees.add(changeAmount) if changeAmount.lte(5400)
            # We have reached our required amount. It's time to prepare the transaction
            transaction = new Transaction(ledger.app.dongle, amount, fees, recipientAddress, finalOutputs, changePath)
            completion.success(transaction)
          else if hasNext is true
            # Continue to collect funds
            done()
          else if hadNetworkFailure
            completion.failure(Errors.NetworkError)
          else
            completion.failure(Errors.NotEnoughFunds)
    completion.readonly()

  # @param [ledger.Amount] amount
  # @param [ledger.Amount] fees
  # @param [String] recipientAddress
  # @param [Array<ledger.wallet.HDWallet.Account>] inputsAccounts The accounts of the addresses to use in order to perform the transaction
  # @param [ledger.wallet.HDWallet.Account] changeAccount The account to use for the change
  # @param [Function] callback
  # @return [CompletionClosure]
  @createAndPrepare: (amount, fees, recipientAddress, inputsAccounts, changeAccount, callback=undefined) ->
    completion = new CompletionClosure(callback)
    inputsPath = _.flatten(inputsAccount.getHDWalletAccount().getAllAddressesPaths() for inputsAccount in inputsAccounts)
    changePath = changeAccount.getHDWalletAccount().getCurrentChangeAddressPath()
    @create(amount: amount, fees: fees, recipientAddress: recipientAddress, inputsAccounts: inputsAccounts, changeAccount: changeAccount)
    .fail (error) => completion.failure(error)
    .then (tx) =>
      tx.prepare()
      .then () => completion.success(tx)
      .fail (error) => completion.failure(error)
    completion.readonly()
