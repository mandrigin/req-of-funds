import Foundation
import CreateML
import CoreML
import NaturalLanguage

/// Document Classifier Training Tool
/// Trains an MLTextClassifier using CreateML with Transfer Learning
/// Outputs a compiled .mlmodelc ready for use in the RFF app

// MARK: - Configuration

struct TrainingConfig {
    /// Path to training data JSON
    let trainingDataPath: String
    /// Output directory for the trained model
    let outputDirectory: String
    /// Model filename (without extension)
    let modelName: String
    /// Minimum training iterations
    let minIterations: Int
    /// Maximum training iterations
    let maxIterations: Int
    /// Validation split (0.0 to 1.0)
    let validationSplit: Double

    static let `default` = TrainingConfig(
        trainingDataPath: "../../RFF/RFF/Resources/TrainingData.json",
        outputDirectory: "../../RFF/RFF/Resources",
        modelName: "DocumentClassifier",
        minIterations: 10,
        maxIterations: 100,
        validationSplit: 0.2
    )
}

// MARK: - Training Data Structure

struct TrainingExample: Codable {
    let text: String
    let label: String
}

// MARK: - Main Training Logic

func loadTrainingData(from path: String) throws -> [TrainingExample] {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    return try decoder.decode([TrainingExample].self, from: data)
}

func trainClassifier(config: TrainingConfig) throws {
    print("Document Classifier Training Tool")
    print("==================================")
    print("")

    // Load training data
    print("Loading training data from: \(config.trainingDataPath)")
    let examples = try loadTrainingData(from: config.trainingDataPath)
    print("Loaded \(examples.count) training examples")

    // Validate categories
    let categories = Set(examples.map { $0.label })
    print("Categories found: \(categories.sorted().joined(separator: ", "))")

    for category in categories {
        let count = examples.filter { $0.label == category }.count
        print("  - \(category): \(count) examples")
    }
    print("")

    // Prepare data for CreateML
    print("Preparing data for training...")
    var dataTable: [[String: String]] = []
    for example in examples {
        dataTable.append(["text": example.text, "label": example.label])
    }

    // Create MLDataTable
    let trainingData = try MLDataTable(dictionary: ["text": dataTable.map { $0["text"]! },
                                                      "label": dataTable.map { $0["label"]! }])

    // Split into training and validation sets
    let (trainData, validationData) = trainingData.randomSplit(by: 1.0 - config.validationSplit)
    print("Training set: \(trainData.rows.count) examples")
    print("Validation set: \(validationData.rows.count) examples")
    print("")

    // Configure the text classifier
    print("Configuring MLTextClassifier...")
    print("  Algorithm: Transfer Learning with ELMo Embedding")
    print("  Max iterations: \(config.maxIterations)")
    print("")

    // Train the model using Transfer Learning with ELMo embedding
    // ELMo (Embeddings from Language Models) provides contextualized word representations
    let parameters = MLTextClassifier.ModelParameters(
        algorithm: .transferLearning(.elmoEmbedding, revision: 1)
    )

    print("Training model...")
    let startTime = Date()

    let classifier = try MLTextClassifier(
        trainingData: trainData,
        textColumn: "text",
        labelColumn: "label",
        parameters: parameters
    )

    let trainingTime = Date().timeIntervalSince(startTime)
    print("Training completed in \(String(format: "%.2f", trainingTime)) seconds")
    print("")

    // Evaluate the model
    print("Evaluating model on validation set...")
    let evaluationMetrics = classifier.evaluation(on: validationData, textColumn: "text", labelColumn: "label")

    let accuracy = (1.0 - evaluationMetrics.classificationError) * 100
    print("Validation Accuracy: \(String(format: "%.2f%%", accuracy))")
    print("Classification Error: \(String(format: "%.2f%%", evaluationMetrics.classificationError * 100))")
    print("")

    // Save the model
    let outputURL = URL(fileURLWithPath: config.outputDirectory)
        .appendingPathComponent(config.modelName)
        .appendingPathExtension("mlmodel")

    print("Saving model to: \(outputURL.path)")
    try classifier.write(to: outputURL)
    print("Model saved successfully!")
    print("")

    // Compile the model for deployment
    print("Compiling model for deployment...")
    let compiledURL = try MLModel.compileModel(at: outputURL)
    let destinationURL = URL(fileURLWithPath: config.outputDirectory)
        .appendingPathComponent(config.modelName)
        .appendingPathExtension("mlmodelc")

    // Remove existing compiled model if present
    if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
    }

    try FileManager.default.copyItem(at: compiledURL, to: destinationURL)
    print("Compiled model saved to: \(destinationURL.path)")
    print("")

    // Test predictions
    print("Testing predictions...")
    let testCases = [
        "Invoice #123 for services rendered, total amount due $5,000",
        "Purchase Order PO-2026-001 for 50 laptops at $1,200 each",
        "Grant application for community health program, requesting $100,000",
        "Expense reimbursement for business travel, receipts attached, total $450"
    ]

    for testCase in testCases {
        let prediction = try classifier.prediction(from: testCase)
        print("  Input: \"\(testCase.prefix(50))...\"")
        print("  Predicted: \(prediction)")
        print("")
    }

    print("Training complete!")
    print("")
    print("To use this model in your app:")
    print("1. Add \(config.modelName).mlmodelc to your Xcode project")
    print("2. Ensure it's included in the app bundle (Copy Bundle Resources)")
    print("3. Use DocumentClassifier.shared.loadModel() at app startup")
}

// MARK: - Entry Point

do {
    // Parse command line arguments for custom paths
    let arguments = CommandLine.arguments
    var config = TrainingConfig.default

    if arguments.count > 1 {
        config = TrainingConfig(
            trainingDataPath: arguments[1],
            outputDirectory: arguments.count > 2 ? arguments[2] : config.outputDirectory,
            modelName: config.modelName,
            minIterations: config.minIterations,
            maxIterations: config.maxIterations,
            validationSplit: config.validationSplit
        )
    }

    try trainClassifier(config: config)
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
